import argparse
import asyncio
from asyncio import TaskGroup
import base64
import html
from importlib import resources
import ipaddress
import logging

from aiohttp import web
from aiohttp_remotes import XForwardedFiltered
import asyncpg
from limits import RateLimitItem, RateLimitItemPerSecond
from limits.aio.storage import MemoryStorage
from limits.aio.strategies import MovingWindowRateLimiter

from .auth import DbAuth

logger = logging.getLogger(__name__)

_CHANGE_PASSWORD_HTML = resources.files("db_auth").joinpath("change_password.html").read_text()


async def check_client_password(request: web.Request, user: str, password: str) -> bool:
    """Checks a password, limiting failures per client IP.

    Callers that don't forward the client IP aren't limited.
    """
    auth: DbAuth = request.app["auth"]
    limiter: MovingWindowRateLimiter | None = request.app["failed_logins_limiter"]
    limit: RateLimitItem | None = request.app["failed_logins_limit"]
    client = request.remote
    if limiter is None or limit is None or client is None or ipaddress.ip_address(client).is_loopback:
        return await auth.check_password(user, password)
    if not await limiter.test(limit, client):
        logger.warning("Too many failed logins from %s, refusing login for %s", client, user)
        return False
    valid = await auth.check_password(user, password)
    if not valid:
        await limiter.hit(limit, client)
    return valid


async def check_password_route(request: web.Request) -> web.Response:
    data = await request.post()
    user = data.get("user")
    password = data.get("password")
    if not isinstance(user, str) or not isinstance(password, str):
        raise web.HTTPBadRequest()
    valid = await check_client_password(request, user, password)
    return web.json_response({"valid": valid}, status=200 if valid else 403)


async def user_exists_route(request: web.Request) -> web.Response:
    user = request.query.get("user")
    if not isinstance(user, str):
        raise web.HTTPBadRequest()
    auth: DbAuth = request.app["auth"]
    exists = await auth.user_exists(user)
    return web.json_response({"exists": exists}, status=200 if exists else 404)


async def scram_sha_256_route(request: web.Request) -> web.Response:
    user = request.query.get("user")
    if not isinstance(user, str):
        raise web.HTTPBadRequest()
    auth: DbAuth = request.app["auth"]
    scram = await auth.get_scram_sha256(user)
    if scram is None:
        raise web.HTTPNotFound()
    return web.json_response({"scram_sha256": scram})


async def set_password_route(request: web.Request) -> web.Response:
    data = await request.post()
    user = data.get("user")
    new_password = data.get("password")
    if not isinstance(user, str) or not isinstance(new_password, str):
        raise web.HTTPBadRequest()
    auth: DbAuth = request.app["auth"]
    try:
        if not await auth.set_password(user, new_password):
            raise web.HTTPNotFound(text="User not found")
    except ValueError as e:
        raise web.HTTPBadRequest(text=str(e))
    return web.Response(status=201)


def _change_password_page(message: str = "") -> web.Response:
    if message:
        message_html = f"<p><b>{html.escape(message)}</b></p>"
    else:
        message_html = ""
    return web.Response(
        text=_CHANGE_PASSWORD_HTML.replace("%message%", message_html),
        content_type="text/html",
    )


async def oauth2_route(request: web.Request) -> web.Response:
    data = await request.post()
    grant_type = data.get("grant_type")
    user = data.get("username")
    password = data.get("password")
    if not grant_type:
        return web.json_response({"error": "invalid_request"}, status=400)
    if grant_type != "password":
        return web.json_response({"error": "unsupported_grant_type"}, status=400)
    if not isinstance(user, str) or not isinstance(password, str):
        return web.json_response({"error": "invalid_request"}, status=400)
    if not await check_client_password(request, user, password):
        return web.json_response({"error": "invalid_grant"}, status=400)
    # Dummy response.
    return web.json_response(
        {
            "access_token": "mylittleserver",
            "token_type": "https://github.com/abbradar/mylittleserver",
        }
    )


async def nginx_check_route(request: web.Request) -> web.Response:
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Basic "):
        raise web.HTTPUnauthorized(headers={"WWW-Authenticate": "Basic"})
    try:
        decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
        user, password = decoded.split(":", 1)
    except (ValueError, UnicodeDecodeError):
        raise web.HTTPUnauthorized(headers={"WWW-Authenticate": "Basic"})
    if not await check_client_password(request, user, password):
        raise web.HTTPUnauthorized(headers={"WWW-Authenticate": "Basic"})
    return web.Response(status=200)


async def change_password_get_route(request: web.Request) -> web.Response:
    return _change_password_page()


async def change_password_post_route(request: web.Request) -> web.Response:
    data = await request.post()
    user = data.get("user")
    old_password = data.get("old_password")
    new_password = data.get("new_password")
    if (
        not isinstance(user, str)
        or not isinstance(old_password, str)
        or not isinstance(new_password, str)
    ):
        return _change_password_page("All fields are required.")
    auth: DbAuth = request.app["auth"]
    if not await check_client_password(request, user, old_password):
        return _change_password_page("Wrong user or password.")
    try:
        if not await auth.set_password(user, new_password):
            raise RuntimeError(f"User {user} has vanished")
    except ValueError:
        return _change_password_page("The new password contains characters that aren't allowed.")
    return _change_password_page("Password changed successfully.")


def create_app(
    auth: DbAuth,
    *,
    failed_logins_limit: RateLimitItem | None = None,
    privileged: bool = False,
) -> web.Application:
    app = web.Application(middlewares=[XForwardedFiltered({"127.0.0.1", "::1"}).middleware])
    app["auth"] = auth
    app["failed_logins_limit"] = failed_logins_limit
    app["failed_logins_limiter"] = (
        MovingWindowRateLimiter(MemoryStorage()) if failed_logins_limit is not None else None
    )

    # For our own plugins.
    app.router.add_route("POST", "/check_password", check_password_route)
    app.router.add_route("GET", "/user_exists", user_exists_route)
    if privileged:
        app.router.add_route("GET", "/scram_sha_256", scram_sha_256_route)
        app.router.add_route("POST", "/set_password", set_password_route)

    # For existing protocols.
    app.router.add_route("POST", "/oauth2", oauth2_route)

    app.router.add_route("GET", "/nginx/check", nginx_check_route)

    app.router.add_route("GET", "/ui/change_password", change_password_get_route)
    app.router.add_route("POST", "/ui/change_password", change_password_post_route)

    return app


async def amain():
    argparser = argparse.ArgumentParser(
        prog="db_auth",
        description="Web server for authorization via MyLittleServer's users table",
    )
    argparser.add_argument("database")
    argparser.add_argument("-u", "--user")
    argparser.add_argument("-H", "--host", default="localhost")
    argparser.add_argument("--port", type=int)
    argparser.add_argument("--unsafe-port", type=int)
    argparser.add_argument(
        "--failed-logins-burst",
        type=int,
        default=5,
        help="failed logins allowed per client IP within the period (0 disables)",
    )
    argparser.add_argument(
        "--failed-logins-period",
        type=int,
        default=30,
        help="period in seconds for the failed logins limit",
    )
    args = argparser.parse_args()

    logging.basicConfig(level=logging.INFO)

    if args.port is None and args.unsafe_port is None:
        raise RuntimeError("At least one of port or an unsafe port must be specified.")

    pool = await asyncpg.create_pool(min_size=1, max_size=5, database=args.database, user=args.user)
    auth = DbAuth(pool)
    failed_logins_limit = None
    if args.failed_logins_burst > 0:
        failed_logins_limit = RateLimitItemPerSecond(
            args.failed_logins_burst, args.failed_logins_period
        )

    async with TaskGroup() as group:
        if args.port:
            app = create_app(auth, failed_logins_limit=failed_logins_limit)
            group.create_task(
                web._run_app(app, host=args.host, port=args.port, access_log=None)
            )
        if args.unsafe_port:
            unsafe_app = create_app(auth, failed_logins_limit=failed_logins_limit, privileged=True)
            group.create_task(
                web._run_app(
                    unsafe_app, host=args.host, port=args.unsafe_port, access_log=None
                )
            )
        while True:
            await asyncio.sleep(3600)


def main():
    asyncio.run(amain())


if __name__ == "__main__":
    main()
