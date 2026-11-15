"""Owner authentication, one-time provisioning, and server-side sessions."""

from __future__ import annotations

import hashlib
import ipaddress
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from fastapi import Depends, HTTPException, Request, status
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, joinedload

from app.config import Settings
from app.database import get_session
from app.models import (
    AuthEvent,
    AuthSession,
    LoginThrottle,
    NativeAuthSession,
    NativeRefreshToken,
    OwnerAccount,
    Product,
    UserAccount,
    utc_now,
)
from app.security import hash_password, verify_password

SESSION_COOKIE_NAME = "spare_parts_session"
CSRF_COOKIE_NAME = "spare_parts_csrf"
PASSWORD_MIN_LENGTH = 15
PASSWORD_MAX_LENGTH = 1024

# An unknown login still performs one password verification to reduce account enumeration.
_DUMMY_PASSWORD_HASH = hash_password(secrets.token_urlsafe(32))


class InvalidCredentials(Exception):
    """Raised for unknown, disabled, or incorrectly authenticated accounts."""


class LoginTemporarilyLimited(Exception):
    """Raised when a client peer is in a configured failed-login lockout window."""


class OwnerAlreadyProvisioned(Exception):
    """Raised when the one-time owner bootstrap has already been completed."""


class InvalidOwnerInput(ValueError):
    """Raised when a login name or initial password fails validation."""


@dataclass(frozen=True)
class AuthContext:
    user: UserAccount
    session: AuthSession | NativeAuthSession
    transport: str = "cookie"


def normalize_login_name(value: str) -> str:
    """Use trimmed, case-insensitive login names; this is not an email address."""
    return value.strip().casefold()


def validate_owner_credentials(login_name: str, password: str) -> tuple[str, str]:
    normalized = normalize_login_name(login_name)
    if not normalized or len(normalized) > 254:
        raise InvalidOwnerInput("Login name must contain 1 to 254 characters.")
    if len(password) < PASSWORD_MIN_LENGTH:
        raise InvalidOwnerInput(f"Password must contain at least {PASSWORD_MIN_LENGTH} characters.")
    if len(password) > PASSWORD_MAX_LENGTH:
        raise InvalidOwnerInput(f"Password must not exceed {PASSWORD_MAX_LENGTH} characters.")
    return normalized, password


def provision_owner(session: Session, login_name: str, password: str) -> OwnerAccount:
    """Create the sole owner row; callers control the surrounding transaction."""
    normalized, password = validate_owner_credentials(login_name, password)
    if session.get(OwnerAccount, 1) is not None:
        raise OwnerAlreadyProvisioned("An owner account is already provisioned.")

    owner = OwnerAccount(id=1, login_name=normalized, password_hash=hash_password(password))
    session.add(owner)
    session.flush()
    user = UserAccount(
        login_name=normalized,
        password_hash=owner.password_hash,
        role="owner",
        is_active=True,
        created_at=owner.created_at,
    )
    session.add(user)
    session.flush()
    session.add(AuthEvent(legacy_owner_id=owner.id, actor_id=user.id, event_type="owner_provisioned"))
    return owner


def provision_attendant(session: Session, login_name: str, password: str) -> UserAccount:
    """Create a separately named attendant account with no owner capabilities."""
    normalized, password = validate_owner_credentials(login_name, password)
    user = UserAccount(
        login_name=normalized,
        password_hash=hash_password(password),
        role="attendant",
        is_active=True,
    )
    session.add(user)
    session.flush()
    return user


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _aware(value: datetime) -> datetime:
    """SQLite may return naive datetimes for timezone-aware columns."""
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def _client_digest(client_host: str | None) -> str:
    """Digest the ASGI peer address; forwarded headers are intentionally never read."""
    try:
        address = str(ipaddress.ip_address(client_host or ""))
    except ValueError:
        address = "unknown"
    return _digest(f"client:{address}")


def prune_auth_data(
    session: Session, settings: Settings, now: datetime | None = None
) -> dict[str, int]:
    """Delete expired throttle, audit, and session rows according to configured retention."""
    current = now or utc_now()
    throttle_result = session.execute(
        delete(LoginThrottle).where(
            LoginThrottle.window_started_at
            < current - timedelta(seconds=settings.login_throttle_retention_seconds),
            (LoginThrottle.locked_until.is_(None)) | (LoginThrottle.locked_until <= current),
        )
    )
    event_result = session.execute(
        delete(AuthEvent).where(
            AuthEvent.occurred_at < current - timedelta(days=settings.auth_event_retention_days)
        )
    )
    session_result = session.execute(
        delete(AuthSession).where(
            (AuthSession.revoked_at.is_not(None))
            | (AuthSession.idle_expires_at <= current)
            | (AuthSession.absolute_expires_at <= current)
        )
    )
    expired_native_ids = session.scalars(
        select(NativeAuthSession.id).where(
            (NativeAuthSession.revoked_at.is_not(None))
            | (NativeAuthSession.idle_expires_at <= current)
            | (NativeAuthSession.absolute_expires_at <= current)
        )
    ).all()
    if expired_native_ids:
        session.execute(
            delete(NativeRefreshToken).where(NativeRefreshToken.session_id.in_(expired_native_ids))
        )
    native_session_result = session.execute(
        delete(NativeAuthSession).where(NativeAuthSession.id.in_(expired_native_ids))
    )
    return {
        "throttles": max(throttle_result.rowcount or 0, 0),
        "events": max(event_result.rowcount or 0, 0),
        "sessions": max(session_result.rowcount or 0, 0)
        + max(native_session_result.rowcount or 0, 0),
    }


def _get_or_create_throttle(session: Session, client_digest: str, now: datetime) -> LoginThrottle:
    throttle = session.scalar(
        select(LoginThrottle).where(LoginThrottle.client_digest == client_digest).with_for_update()
    )
    if throttle is not None:
        return throttle

    throttle = LoginThrottle(client_digest=client_digest, window_started_at=now, failed_attempts=0)
    session.add(throttle)
    try:
        session.flush()
    except IntegrityError:
        # A concurrent first login attempt may have inserted the same throttle row.
        session.rollback()
        throttle = session.scalar(
            select(LoginThrottle).where(LoginThrottle.client_digest == client_digest).with_for_update()
        )
        if throttle is None:
            raise
    return throttle


def authenticate_owner(
    session: Session,
    login_name: str,
    password: str,
    settings: Settings,
    client_host: str | None,
) -> tuple[UserAccount, AuthSession, str, str]:
    """Verify credentials, throttle by transport peer, and create a revocable session."""
    normalized = normalize_login_name(login_name)[:254]
    now = utc_now()
    prune_auth_data(session, settings, now)
    throttle = _get_or_create_throttle(session, _client_digest(client_host), now)

    if throttle.locked_until and _aware(throttle.locked_until) > now:
        session.commit()
        raise LoginTemporarilyLimited

    window_elapsed = now - _aware(throttle.window_started_at) >= timedelta(
        seconds=settings.login_window_seconds
    )
    if window_elapsed or (throttle.locked_until and _aware(throttle.locked_until) <= now):
        throttle.window_started_at = now
        throttle.failed_attempts = 0
        throttle.locked_until = None

    user = session.scalar(select(UserAccount).where(UserAccount.login_name == normalized))
    user_matches = user is not None and user.is_active
    encoded_password = user.password_hash if user_matches else _DUMMY_PASSWORD_HASH
    try:
        password_matches = verify_password(password, encoded_password)
    except (ValueError, TypeError):
        password_matches = False

    if not user_matches or not password_matches:
        throttle.failed_attempts += 1
        if throttle.failed_attempts >= settings.login_failure_limit:
            throttle.locked_until = now + timedelta(seconds=settings.login_lockout_seconds)
            # Record one event at the point this peer is limited, not every request
            # during the lockout window.
            session.add(AuthEvent(event_type="login_limited"))
        session.commit()
        raise InvalidCredentials

    throttle.failed_attempts = 0
    throttle.locked_until = None
    throttle.window_started_at = now
    session_token = secrets.token_urlsafe(32)
    csrf_token = secrets.token_urlsafe(32)
    absolute_expires_at = now + timedelta(seconds=settings.session_absolute_seconds)
    auth_session = AuthSession(
        legacy_owner_id=1 if user.role == "owner" else None,
        user_id=user.id,
        token_hash=_digest(session_token),
        csrf_token_hash=_digest(csrf_token),
        created_at=now,
        last_seen_at=now,
        idle_expires_at=min(
            now + timedelta(seconds=settings.session_idle_seconds), absolute_expires_at
        ),
        absolute_expires_at=absolute_expires_at,
    )
    session.add(auth_session)
    session.add(AuthEvent(legacy_owner_id=1 if user.role == "owner" else None,
                          actor_id=user.id, event_type="login_succeeded"))
    session.commit()
    return user, auth_session, session_token, csrf_token


def _load_auth_context(request: Request, session: Session) -> AuthContext | None:
    raw_token = request.cookies.get(SESSION_COOKIE_NAME)
    if not raw_token:
        return None
    auth_session = session.scalar(
        select(AuthSession)
        .options(joinedload(AuthSession.user))
        .where(AuthSession.token_hash == _digest(raw_token))
    )
    if auth_session is None:
        return None

    now = utc_now()
    expired = (
        auth_session.revoked_at is not None
        or _aware(auth_session.idle_expires_at) <= now
        or _aware(auth_session.absolute_expires_at) <= now
        or not auth_session.user.is_active
    )
    if expired:
        if auth_session.revoked_at is None:
            auth_session.revoked_at = now
            session.commit()
        return None

    activity_interval = min(
        request.app.state.settings.session_activity_write_interval_seconds,
        max(1, request.app.state.settings.session_idle_seconds // 2),
    )
    if now - _aware(auth_session.last_seen_at) >= timedelta(seconds=activity_interval):
        auth_session.last_seen_at = now
        auth_session.idle_expires_at = min(
            now + timedelta(seconds=request.app.state.settings.session_idle_seconds),
            _aware(auth_session.absolute_expires_at),
        )
        session.commit()
    return AuthContext(user=auth_session.user, session=auth_session, transport="cookie")


def get_optional_auth_context(
    request: Request, session: Session = Depends(get_session)
) -> AuthContext | None:
    return _load_auth_context(request, session)


def get_current_auth(
    request: Request, session: Session = Depends(get_session)
) -> AuthContext:
    authorization = request.headers.get("authorization")
    if authorization is not None:
        if request.app.state.settings.native_https_required and request.url.scheme != "https":
            raise HTTPException(status_code=403, detail="HTTPS is required for bearer authentication.")
        scheme, separator, token = authorization.partition(" ")
        if scheme.casefold() != "bearer" or not separator or not token or len(token) > 256:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Authentication required.",
                headers={"WWW-Authenticate": "Bearer"},
            )
        from app.native_auth import load_native_auth_context

        context = load_native_auth_context(session, token)
        if context is None:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Authentication required.",
                headers={"WWW-Authenticate": "Bearer"},
            )
        return context
    context = _load_auth_context(request, session)
    if context is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return context


def require_owner(context: AuthContext = Depends(get_current_auth)) -> AuthContext:
    """Server-side owner authorization dependency for administrative operations."""
    if context.user.role != "owner":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Owner access required.")
    return context


def require_roles(*roles: str):
    """Build a reusable dependency that allows only trusted persisted user roles."""

    def dependency(context: AuthContext = Depends(get_current_auth)) -> AuthContext:
        if context.user.role not in roles:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Insufficient permissions.")
        return context

    return dependency


require_attendant = require_roles("attendant")


def can_view_product(context: AuthContext, product: Product) -> bool:
    return (
        context.user.role == "owner"
        or product.approval_status == "approved"
        or product.submitted_by == context.user.id
    )


def require_csrf(request: Request, context: AuthContext) -> None:
    if context.transport == "bearer":
        return
    cookie_token = request.cookies.get(CSRF_COOKIE_NAME, "")
    submitted_token = request.headers.get("X-CSRF-Token", "")
    if (
        not cookie_token
        or not submitted_token
        or not secrets.compare_digest(cookie_token, submitted_token)
        or not secrets.compare_digest(_digest(cookie_token), context.session.csrf_token_hash)
    ):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="CSRF validation failed.")
