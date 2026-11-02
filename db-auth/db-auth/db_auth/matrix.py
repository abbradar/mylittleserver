import logging

from synapse.api.errors import HttpResponseException
from synapse.module_api import JsonDict, ModuleApi

logger = logging.getLogger(__name__)


class DBAuthProvider:
    _api: ModuleApi
    _url: str

    def __init__(self, config: dict[str, object], api: ModuleApi):
        self._api = api
        url = config.get("url")
        if not isinstance(url, str):
            raise TypeError("url is required and must be a string")
        self._url = url.rstrip("/")

        api.register_password_auth_provider_callbacks(
            auth_checkers={
                ("m.login.password", ("password",)): self.check_password,
            },
            check_3pid_auth=self.check_3pid_auth,
        )

    async def _check_password(self, localpart: str, password: str) -> bool:
        try:
            await self._api.http_client.post_urlencoded_get_json(
                f"{self._url}/check_password", {"user": localpart, "password": password}
            )
        except HttpResponseException as e:
            if e.code != 403:
                logger.error("Error checking password for %s: %s", localpart, e)
            return False
        except Exception:
            logger.exception("Error checking password for %s", localpart)
            return False
        return True

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

        if not await self._check_password(localpart, password):
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

        if not await self._check_password(localpart, password):
            return None

        user_id = self._api.get_qualified_user_id(localpart)
        user_exists = await self._api.check_user_exists(user_id)
        if not user_exists:
            await self._api.register_user(localpart=localpart)

        return user_id, None
