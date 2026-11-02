import base64
import hashlib
import hmac
import re
import secrets

import asyncpg
from passlib.context import CryptContext
from passlib.utils import saslprep

# LEGACY: sha512_crypt hashes are upgraded to bcrypt on login.
CRYPT_CONTEXT = CryptContext(schemes=["bcrypt", "sha512_crypt"], deprecated=["sha512_crypt"])

SCRAM_ITERATIONS = 100_000

_SCRAM_PREFIX = f"{{SCRAM-SHA-256}}{SCRAM_ITERATIONS},"


def _normalize(password: str) -> str | None:
    """Applies SASLprep, like SASL clients and servers do; None if it rejects the password."""
    try:
        return saslprep(password)
    except ValueError:
        return None


def _scram_sha256(normalized: str) -> str:
    """Derives SCRAM-SHA-256 credentials in Dovecot's format."""
    salt = secrets.token_bytes(16)
    salted_password = hashlib.pbkdf2_hmac("sha256", normalized.encode(), salt, SCRAM_ITERATIONS)
    client_key = hmac.digest(salted_password, b"Client Key", "sha256")
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.digest(salted_password, b"Server Key", "sha256")
    fields = (base64.b64encode(value).decode() for value in (salt, stored_key, server_key))
    return _SCRAM_PREFIX + ",".join(fields)


def _scram_needs_update(scram: str | None) -> bool:
    return scram is None or not scram.startswith(_SCRAM_PREFIX)


def _new_credentials(password: str) -> tuple[str, str]:
    normalized = _normalize(password)
    if normalized is None:
        raise ValueError("the password contains characters that aren't allowed")
    return CRYPT_CONTEXT.hash(normalized), _scram_sha256(normalized)


# Valid as a mail local part, XMPP node, Matrix localpart and directory name.
_USER_REGEX = re.compile(r"[a-z0-9][a-z0-9._-]*")

_UPDATE_REGEX = re.compile(r"UPDATE (\d+)")


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
                "SELECT password, scram_sha256 FROM users WHERE name = $1 AND enabled", user
            )
            if row is None:
                return False
            password_hash, scram = row["password"], row["scram_sha256"]
            normalized = _normalize(password)
            valid, new_hash = False, None
            if normalized is not None:
                valid, new_hash = CRYPT_CONTEXT.verify_and_update(normalized, password_hash)
            # LEGACY: passwords without SCRAM credentials may be hashed without normalization.
            if not valid and scram is None and normalized != password:
                valid, new_hash = CRYPT_CONTEXT.verify_and_update(password, password_hash)
                if valid and normalized is not None:
                    new_hash = CRYPT_CONTEXT.hash(normalized)
            # LEGACY: also adds SCRAM credentials to passwords that don't have them.
            needs_scram = normalized is not None and _scram_needs_update(scram)
            if valid and (new_hash is not None or needs_scram):
                await conn.execute(
                    "UPDATE users SET password = $3, scram_sha256 = $4"
                    " WHERE name = $1 AND password = $2",
                    user,
                    password_hash,
                    new_hash or password_hash,
                    _scram_sha256(normalized) if normalized is not None else None,
                )
            return valid

    async def user_exists(self, user: str) -> bool:
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT COUNT(*) FROM users WHERE name = $1 AND enabled", user
            )
            return row[0] > 0

    async def get_scram_sha256(self, user: str) -> str | None:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                "SELECT scram_sha256 FROM users WHERE name = $1 AND enabled", user
            )

    async def set_password(self, user: str, new_password: str) -> bool:
        password_hash, scram = _new_credentials(new_password)
        async with self._pool.acquire() as conn:
            ret = await conn.execute(
                "UPDATE users SET password = $2, scram_sha256 = $3 WHERE name = $1 AND enabled",
                user,
                password_hash,
                scram,
            )
            affected = _parse_update_affected(ret)
            return affected > 0

    async def set_user(self, user: str, password: str, enabled: bool):
        if not _USER_REGEX.fullmatch(user):
            raise ValueError(
                "the user name must consist of lowercase ASCII letters, digits, '.', '_' and '-',"
                " and start with a letter or digit"
            )
        password_hash, scram = _new_credentials(password)
        async with self._pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO users (name, password, scram_sha256, enabled) VALUES ($1, $2, $3, $4)"
                " ON CONFLICT (name) DO UPDATE SET password = EXCLUDED.password,"
                " scram_sha256 = EXCLUDED.scram_sha256, enabled = EXCLUDED.enabled",
                user,
                password_hash,
                scram,
                enabled,
            )
