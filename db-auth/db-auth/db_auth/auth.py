import re

from passlib.context import CryptContext
import asyncpg


_UPDATE_REGEX = re.compile(r"UPDATE (\d+)")


_CRYPT_CONTEXT = CryptContext(schemes=["bcrypt", "sha512_crypt"], deprecated=["sha512_crypt"])


def _parse_update_affected(status: str) -> int:
    match = _UPDATE_REGEX.fullmatch(status)
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
            valid, new_hash = _CRYPT_CONTEXT.verify_and_update(password, password_hash)
            if valid and new_hash is not None:
                await conn.execute(
                    "UPDATE users SET password = $2 WHERE name = $1",
                    user,
                    new_hash,
                )
            return valid

    async def user_exists(self, user: str) -> bool:
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT COUNT(*) FROM users WHERE name = $1 AND enabled", user
            )
            return row[0] > 0

    async def set_password(self, user: str, new_password: str):
        async with self._pool.acquire() as conn:
            password_hash = _CRYPT_CONTEXT.hash(new_password)
            ret = await conn.execute(
                "UPDATE users SET password = $2 WHERE name = $1 AND enabled",
                user,
                password_hash,
            )
            affected = _parse_update_affected(ret)
            return affected > 0
