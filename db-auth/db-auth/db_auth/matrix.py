import logging

import asyncpg
from synapse.module_api import JsonDict, ModuleApi

from .auth import DbAuth

logger = logging.getLogger(__name__)


class DBAuthProvider:
    def __init__(self, config: dict[str, object], api: ModuleApi):
        self._api = api
        self._database = config.get("database", "mylittleserver")
        self._auth: DbAuth | None = None

        api.register_password_auth_provider_callbacks(
            auth_checkers={
                ("m.login.password", ("password",)): self.check_password,
            },
        )

    async def _get_auth(self) -> DbAuth:
        if self._auth is None:
            pool = await asyncpg.create_pool(database=self._database)
            self._auth = DbAuth(pool)
        return self._auth

    async def check_password(
        self,
        username: str,
        login_type: str,
        login_dict: JsonDict,
    ) -> tuple[str, None] | None:
        password = login_dict.get("password")
        if not password:
            return None

        if username.startswith("@"):
            localpart = username.split(":", 1)[0][1:]
        else:
            localpart = username

        try:
            auth = await self._get_auth()
            valid = await auth.check_password(localpart, password)
        except Exception:
            logger.exception("Error checking password for %s", localpart)
            return None

        if not valid:
            return None

        user_id = self._api.get_qualified_user_id(localpart)
        return user_id, None
