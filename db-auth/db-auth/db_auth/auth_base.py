from passlib.context import CryptContext

CRYPT_CONTEXT = CryptContext(schemes=["bcrypt", "sha512_crypt"], deprecated=["sha512_crypt"])
