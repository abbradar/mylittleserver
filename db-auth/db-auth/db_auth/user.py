import argparse
import asyncio
import getpass
import secrets
import string
import sys

import asyncpg

from .auth import DbAuth


async def amain():
    argparser = argparse.ArgumentParser(
        prog="db-auth-user",
        description="Create or update a user in MyLittleServer's users table",
    )
    argparser.add_argument("database")
    enabled_group = argparser.add_mutually_exclusive_group()
    enabled_group.add_argument(
        "-e", dest="enabled", action="store_true", default=True, help="enable the user (default)"
    )
    enabled_group.add_argument("-d", dest="enabled", action="store_false", help="disable the user")
    password_group = argparser.add_mutually_exclusive_group()
    password_group.add_argument(
        "-s", dest="stdin", action="store_true", help="read the password from stdin"
    )
    password_group.add_argument(
        "-g", dest="generate", action="store_true", help="generate and print a password"
    )
    argparser.add_argument("user")
    args = argparser.parse_args()

    if args.generate:
        alphabet = string.ascii_letters + string.digits
        password = "".join(secrets.choice(alphabet) for _ in range(20))
    elif args.stdin:
        password = sys.stdin.readline().rstrip("\n")
    else:
        password = getpass.getpass()
    if not password:
        argparser.error("the password must not be empty")

    pool = await asyncpg.create_pool(min_size=1, max_size=1, database=args.database)
    try:
        await DbAuth(pool).set_user(args.user, password, args.enabled)
    except ValueError as e:
        argparser.error(str(e))
    finally:
        await pool.close()
    if args.generate:
        print(password)


def main():
    asyncio.run(amain())


if __name__ == "__main__":
    main()
