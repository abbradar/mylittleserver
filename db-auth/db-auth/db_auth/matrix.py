import logging

import psycopg2.pool
from twisted.internet.threads import deferToThread
from synapse.module_api import JsonDict, ModuleApi

from .auth_psycopg2 import DbAuthPsycopg2 as DbAuth

logger = logging.getLogger(__name__)


class DBAuthProvider:
    _api: ModuleApi
    _auth: DbAuth

    def __init__(self, config: dict[str, object], api: ModuleApi):
        self._api = api
        database = config.get("database", "mylittleserver")
        if not isinstance(database, str):
            raise TypeError(f"database must be a string, got {type(database).__name__}")
        pool = psycopg2.pool.ThreadedConnectionPool(1, 5, database=database)
        self._auth = DbAuth(pool)

        api.register_password_auth_provider_callbacks(
            auth_checkers={
                ("m.login.password", ("password",)): self.check_password,
            },
            check_3pid_auth=self.check_3pid_auth,
        )

    async def check_password(
        self,
        user_id: str,
        login_type: str,
        login_dict: JsonDict,
    ) -> tuple[str, None] | None:
        password = login_dict.get("password")
        if not password:
            return None

        if user_id.startswith("@"):
            localpart = user_id.split(":", 1)[0][1:]
        else:
            localpart = user_id
            user_id = self._api.get_qualified_user_id(localpart)

        try:
            valid = await deferToThread(self._auth.check_password, localpart, password)
        except Exception:
            logger.exception("Error checking password for %s", localpart)
            return None

        if not valid:
            return None

        # The user is authenticated.
        if not await self._api.check_user_exists(user_id):
            await self._api.register_user(localpart=localpart)

        return user_id, None

    async def check_3pid_auth(
        self,
        medium: str,
        address: str,
        password: str,
    ) -> tuple[str, None] | None:
        if medium != "email":
            return None

        localpart, _, domain = address.rpartition("@")
        if not localpart or domain != self._api.server_name:
            return None

        try:
            valid = await deferToThread(self._auth.check_password, localpart, password)
        except Exception:
            logger.exception("Error checking password for %s", localpart)
            return None

        if not valid:
            return None

        user_id = self._api.get_qualified_user_id(localpart)
        user_exists = await self._api.check_user_exists(user_id)
        if not user_exists:
            await self._api.register_user(localpart=localpart)

        return user_id, None
