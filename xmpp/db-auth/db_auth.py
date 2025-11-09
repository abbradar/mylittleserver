#!/usr/bin/env python3

import argparse
import re
from passlib.context import CryptContext
import asyncio
from aiohttp import web
import asyncpg


def bool_to_reply(b):
    return web.Response(text="true" if b else "false")


UPDATE_REGEX = re.compile(r"UPDATE (\d+)")


CRYPT_CONTEXT = CryptContext(schemes=["bcrypt", "sha512_crypt"])


def parse_update_affected(status):
    match = UPDATE_REGEX.fullmatch(status)
    if match is None:
        raise RuntimeError("Unexpected status format")
    return int(match.group(1))


async def not_implemented_route(request):
    raise web.HTTPNotImplemented()


async def check_password(request):
    user = request.query.get("user")
    password = request.query.get("pass")
    if not user or not password:
        raise web.HTTPBadRequest()

    async with request.app["pool"].acquire() as conn:
        row = await conn.fetchrow(
            "SELECT password FROM users WHERE name = $1 AND enabled", user
        )
        if row is None:
            return False
        password_hash = row["password"]
        return CRYPT_CONTEXT.verify(password, password_hash)


async def check_password_route(request):
    return bool_to_reply(await check_password(request))


async def user_exists(request):
    user = request.query.get("user")
    if not user:
        raise web.HTTPBadRequest()

    async with request.app["pool"].acquire() as conn:
        row = await conn.fetchrow(
            "SELECT COUNT(*) FROM users WHERE name = $1 AND enabled", user
        )
        return row[0] > 0


async def user_exists_route(request):
    return bool_to_reply(await user_exists(request))


async def set_password_route(request):
    data = await request.post()
    user = data.get("user")
    new_password = data.get("pass")
    if not user or not new_password:
        raise web.HTTPBadRequest()

    async with request.app["pool"].acquire() as conn:
        password_hash = CRYPT_CONTEXT.hash(new_password)
        ret = await conn.execute(
            "UPDATE users SET password = $2 WHERE name = $1 AND enabled",
            user,
            password_hash,
        )
        affected = parse_update_affected(ret)
        if affected == 0:
            raise web.HTTPNotFound(text="User not found")

    return web.Response(status=201)


async def async_main():
    argparser = argparse.ArgumentParser(
        prog="db_auth",
        description="Web server for authorization via MyLittleServer's users table",
    )
    argparser.add_argument("database")
    argparser.add_argument("-u", "--user")
    argparser.add_argument("-H", "--host", default="localhost")
    argparser.add_argument("-p", "--port", type=int, default=8080)
    args = argparser.parse_args()

    app = web.Application()
    app["pool"] = await asyncpg.create_pool(database=args.database, user=args.user)

    app.router.add_route("POST", "/register", not_implemented_route)
    app.router.add_route("GET", "/check_password", check_password_route)
    app.router.add_route("GET", "/user_exists", user_exists_route)
    app.router.add_route("POST", "/set_password", set_password_route)
    app.router.add_route("POST", "/remove_user", not_implemented_route)

    await web._run_app(app, host=args.host, port=args.port)


def main():
    asyncio.run(async_main())


if __name__ == "__main__":
    main()
