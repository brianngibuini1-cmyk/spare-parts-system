"""Password hashing primitives for future account authentication flows."""

from pwdlib import PasswordHash

_password_hash = PasswordHash.recommended()


def hash_password(password: str) -> str:
    """Return a salted password hash. Callers must never store the raw password."""
    if not password:
        raise ValueError("Password must not be empty")
    return _password_hash.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    """Verify a submitted password against its stored hash."""
    if not password or not password_hash:
        return False
    return _password_hash.verify(password, password_hash)
