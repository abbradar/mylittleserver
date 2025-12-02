#!/usr/bin/env python3

import argparse
import re
from passlib.context import CryptContext
import asyncio
from asyncio import TaskGroup
from aiohttp import web
import asyncpg


UPDATE_REGEX = re.compile(r"UPDATE (\d+)")


CRYPT_CONTEXT = CryptContext(schemes=["bcrypt", "sha512_crypt"])


def parse_update_affected(status: str) -> int:
    match = UPDATE_REGEX.fullmatch(status)
    if match is None:
        raise RuntimeError("Unexpected status format")
    return int(match.group(1))


class DbAuth:
    _pool: asyncpg.pool.Pool

    def __init__(self, pool: asyncpg.pool.Pool):
        self._pool = pool

    async def check_password(self, user: str, password: str) -> bool:
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT password FROM users WHERE name = $1 AND enabled", user
            )
            if row is None:
                return False
            password_hash = row["password"]
            return CRYPT_CONTEXT.verify(password, password_hash)

    async def user_exists(self, user: str) -> bool:
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT COUNT(*) FROM users WHERE name = $1 AND enabled", user
            )
            return row[0] > 0

    async def set_password(self, user: str, new_password: str):
        async with self._pool.acquire() as conn:
            password_hash = CRYPT_CONTEXT.hash(new_password)
            ret = await conn.execute(
                "UPDATE users SET password = $2 WHERE name = $1 AND enabled",
                user,
                password_hash,
            )
            affected = parse_update_affected(ret)
            return affected > 0


def bool_to_reply(b: bool) -> web.Response:
    return web.Response(text="true" if b else "false")


async def not_implemented_route(request: web.Request) -> web.Response:
    raise web.HTTPNotImplemented()


async def prosody_check_password_route(request: web.Request) -> web.Response:
    user = request.query.get("user")
    password = request.query.get("pass")
    if not isinstance(user, str) or not isinstance(password, str):
        raise web.HTTPBadRequest()
    auth: DbAuth = request.app["auth"]
    return bool_to_reply(await auth.check_password(user, password))


async def prosody_user_exists_route(request: web.Request) -> web.Response:
    user = request.query.get("user")
    if not isinstance(user, str):
        raise web.HTTPBadRequest()
    auth: DbAuth = request.app["auth"]
    return bool_to_reply(await auth.user_exists(user))


async def prosody_set_password_route(request: web.Request) -> web.Response:
    data = await request.post()
    user = data.get("user")
    new_password = data.get("pass")
    if not isinstance(user, str) or not isinstance(new_password, str):
        raise web.HTTPBadRequest()
    auth: DbAuth = request.app["auth"]
    if not await auth.set_password(user, new_password):
        raise web.HTTPNotFound(text="User not found")
    return web.Response(status=201)


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
    auth: DbAuth = request.app["auth"]
    if not await auth.check_password(user, password):
        return web.json_response({"error": "invalid_grant"}, status=400)
    # Dummy response.
    return web.json_response(
        {
            "access_token": "mylittleserver",
            "token_type": "https://github.com/abbradar/mylittleserver",
        }
    )


def create_app(auth: DbAuth, *, allow_set_password: bool = False) -> web.Application:
    app = web.Application()
    app["auth"] = auth

    app.router.add_route("POST", "/prosody/register", not_implemented_route)
    app.router.add_route("GET", "/prosody/check_password", prosody_check_password_route)
    app.router.add_route("GET", "/prosody/user_exists", prosody_user_exists_route)
    if allow_set_password:
        my_prosody_set_password_route = prosody_set_password_route
    else:
        my_prosody_set_password_route = not_implemented_route
    app.router.add_route("POST", "/prosody/set_password", my_prosody_set_password_route)
    app.router.add_route("POST", "/prosody/remove_user", not_implemented_route)
    app.router.add_route("POST", "/oauth2", oauth2_route)
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
    args = argparser.parse_args()

    if args.port is None and args.unsafe_port is None:
        raise RuntimeError("At least one of port or an unsafe port must be specified.")

    pool = await asyncpg.create_pool(database=args.database, user=args.user)
    auth = DbAuth(pool)

    async with TaskGroup() as group:
        if args.port:
            app = create_app(auth)
            group.create_task(web._run_app(app, host=args.host, port=args.port))
        if args.unsafe_port:
            unsafe_app = create_app(auth, allow_set_password=True)
            group.create_task(
                web._run_app(unsafe_app, host=args.host, port=args.unsafe_port)
            )
        while True:
            await asyncio.sleep(3600)


def main():
    asyncio.run(amain())


if __name__ == "__main__":
    main()
