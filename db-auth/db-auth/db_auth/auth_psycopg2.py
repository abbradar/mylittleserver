import psycopg2.pool

from .auth_base import CRYPT_CONTEXT


class DbAuthPsycopg2:
    _pool: psycopg2.pool.ThreadedConnectionPool

    def __init__(self, pool: psycopg2.pool.ThreadedConnectionPool):
        self._pool = pool

    def check_password(self, user: str, password: str) -> bool:
        conn = self._pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT password FROM users WHERE name = %s AND enabled",
                    (user,),
                )
                row = cur.fetchone()
                if row is None:
                    return False
                password_hash = row[0]
                valid, new_hash = CRYPT_CONTEXT.verify_and_update(password, password_hash)
                if valid and new_hash is not None:
                    cur.execute(
                        "UPDATE users SET password = %s WHERE name = %s AND enabled",
                        (new_hash, user),
                    )
                    conn.commit()
                return valid
        finally:
            self._pool.putconn(conn)

    def user_exists(self, user: str) -> bool:
        conn = self._pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT COUNT(*) FROM users WHERE name = %s AND enabled",
                    (user,),
                )
                row = cur.fetchone()
                return row[0] > 0
        finally:
            self._pool.putconn(conn)

    def set_password(self, user: str, new_password: str) -> bool:
        conn = self._pool.getconn()
        try:
            with conn.cursor() as cur:
                password_hash = CRYPT_CONTEXT.hash(new_password)
                cur.execute(
                    "UPDATE users SET password = %s WHERE name = %s AND enabled",
                    (password_hash, user),
                )
                conn.commit()
                return cur.rowcount > 0
        finally:
            self._pool.putconn(conn)
