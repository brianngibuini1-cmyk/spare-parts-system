"""Opaque rotating-token authentication for native Flutter clients."""

from __future__ import annotations

import secrets
from datetime import timedelta
from threading import Lock
from weakref import WeakValueDictionary

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlalchemy.orm import Session, joinedload

from app.auth import (
    AuthContext,
    InvalidCredentials,
    LoginTemporarilyLimited,
    _aware,
    _client_digest,
    _digest,
    _get_or_create_throttle,
    get_current_auth,
    normalize_login_name,
    prune_auth_data,
    _DUMMY_PASSWORD_HASH,
)
from app.config import Settings
from app.database import get_session
from app.models import (
    AuthEvent,
    NativeAuthSession,
    NativeRefreshToken,
    UserAccount,
    utc_now,
)
from app.security import verify_password

router = APIRouter(prefix="/api/v1/native/auth", tags=["native authentication"])
ACCESS_TOKEN_TYPE = "Bearer"
_REFRESH_LOCKS: WeakValueDictionary[str, "_RefreshLock"] = WeakValueDictionary()
_REFRESH_LOCKS_GUARD = Lock()


class _RefreshLock:
    __slots__ = ("lock", "__weakref__")

    def __init__(self) -> None:
        self.lock = Lock()


def _refresh_lock(token_hash: str) -> _RefreshLock:
    with _REFRESH_LOCKS_GUARD:
        lock = _REFRESH_LOCKS.get(token_hash)
        if lock is None:
            lock = _RefreshLock()
            _REFRESH_LOCKS[token_hash] = lock
        return lock


class NativeLoginRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    login_name: str = Field(min_length=1, max_length=254)
    password: str = Field(min_length=1, max_length=1024)


class NativeRefreshRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    refresh_token: str = Field(min_length=32, max_length=256)


class NativeLogoutRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    refresh_token: str = Field(min_length=32, max_length=256)


class InvalidNativeSession(Exception):
    """Raised for missing, expired, revoked, or invalid native credentials."""


class RefreshTokenReused(InvalidNativeSession):
    """Raised after a consumed refresh token is presented again."""


def _require_secure_transport(request: Request) -> None:
    if request.app.state.settings.native_https_required and request.url.scheme != "https":
        raise HTTPException(status_code=403, detail="HTTPS is required for native authentication.")


def _role_name(user: UserAccount) -> str:
    return "OWNER" if user.role == "owner" else "SHOP_ATTENDANT"


def _limited_access_expiry(now: datetime, settings: Settings, absolute: datetime) -> datetime:
    return min(now + timedelta(seconds=settings.native_access_token_seconds), absolute)


def _token_response(
    user: UserAccount,
    native_session: NativeAuthSession,
    access_token: str,
    refresh_token: str,
    now: datetime,
) -> dict:
    access_expiry = _aware(native_session.access_expires_at)
    idle_expiry = _aware(native_session.idle_expires_at)
    absolute_expiry = _aware(native_session.absolute_expires_at)
    return {
        "access_token": access_token,
        "token_type": ACCESS_TOKEN_TYPE,
        "expires_in": max(0, int((access_expiry - now).total_seconds())),
        "access_expires_at": access_expiry.isoformat(),
        "refresh_token": refresh_token,
        "refresh_expires_at": min(idle_expiry, absolute_expiry).isoformat(),
        "session_expires_at": absolute_expiry.isoformat(),
        "user": {"id": user.id, "login_name": user.login_name, "role": _role_name(user)},
    }


def _new_tokens() -> tuple[str, str]:
    return secrets.token_urlsafe(32), secrets.token_urlsafe(48)


def authenticate_native(
    session: Session,
    login_name: str,
    password: str,
    settings: Settings,
    client_host: str | None,
) -> dict:
    """Verify credentials and create an opaque access/refresh token session."""
    now = utc_now()
    normalized = normalize_login_name(login_name)[:254]
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
    matches = user is not None and user.is_active
    try:
        password_matches = verify_password(password, user.password_hash if matches else _DUMMY_PASSWORD_HASH)
    except (ValueError, TypeError):
        password_matches = False

    if not matches or not password_matches:
        throttle.failed_attempts += 1
        if throttle.failed_attempts >= settings.login_failure_limit:
            throttle.locked_until = now + timedelta(seconds=settings.login_lockout_seconds)
            session.add(AuthEvent(event_type="login_limited"))
        session.commit()
        raise InvalidCredentials

    throttle.failed_attempts = 0
    throttle.locked_until = None
    throttle.window_started_at = now
    access_token, refresh_token = _new_tokens()
    absolute_expiry = now + timedelta(seconds=settings.native_session_absolute_seconds)
    native_session = NativeAuthSession(
        user_id=user.id,
        access_token_hash=_digest(access_token),
        created_at=now,
        last_refresh_at=now,
        idle_expires_at=min(
            now + timedelta(seconds=settings.native_session_idle_seconds), absolute_expiry
        ),
        absolute_expires_at=absolute_expiry,
        access_expires_at=_limited_access_expiry(now, settings, absolute_expiry),
    )
    session.add(native_session)
    session.flush()
    session.add(
        NativeRefreshToken(
            token_hash=_digest(refresh_token),
            session_id=native_session.id,
            issued_at=now,
            expires_at=absolute_expiry,
        )
    )
    session.add(
        AuthEvent(
            legacy_owner_id=1 if user.role == "owner" else None,
            actor_id=user.id,
            event_type="native_login_succeeded",
        )
    )
    session.commit()
    return _token_response(user, native_session, access_token, refresh_token, now)


def load_native_auth_context(session: Session, access_token: str) -> AuthContext | None:
    if not access_token or len(access_token) > 256:
        return None
    native_session = session.scalar(
        select(NativeAuthSession)
        .options(joinedload(NativeAuthSession.user))
        .where(NativeAuthSession.access_token_hash == _digest(access_token))
    )
    if native_session is None:
        return None
    now = utc_now()
    if (
        native_session.revoked_at is not None
        or _aware(native_session.access_expires_at) <= now
        or _aware(native_session.idle_expires_at) <= now
        or _aware(native_session.absolute_expires_at) <= now
        or not native_session.user.is_active
    ):
        return None
    return AuthContext(user=native_session.user, session=native_session, transport="bearer")


def refresh_native_session(session: Session, refresh_token: str, settings: Settings) -> dict:
    """Rotate one refresh token under a parent-session row lock."""
    token_hash = _digest(refresh_token)
    # This process-local lock also makes single-worker SQLite/dev behavior
    # deterministic. The database row lock remains the cross-worker guard.
    lock = _refresh_lock(token_hash)
    with lock.lock:
        return _rotate_native_session(session, token_hash, settings)


def _rotate_native_session(session: Session, token_hash: str, settings: Settings) -> dict:
    token_row = session.get(NativeRefreshToken, token_hash)
    if token_row is None:
        raise InvalidNativeSession
    native_session = session.scalar(
        select(NativeAuthSession)
        .where(NativeAuthSession.id == token_row.session_id)
        .with_for_update()
    )
    if native_session is None:
        raise InvalidNativeSession
    # Refresh the identity-map object after acquiring the parent lock: another
    # request may have consumed this row while this request waited.
    session.refresh(token_row)
    now = utc_now()
    if native_session.revoked_at is not None:
        raise InvalidNativeSession
    if token_row.consumed_at is not None:
        native_session.revoked_at = now
        session.add(
            AuthEvent(
                legacy_owner_id=1 if native_session.user.role == "owner" else None,
                actor_id=native_session.user_id,
                event_type="native_refresh_reuse_detected",
            )
        )
        session.commit()
        raise RefreshTokenReused
    if (
        not native_session.user.is_active
        or _aware(token_row.expires_at) <= now
        or _aware(native_session.idle_expires_at) <= now
        or _aware(native_session.absolute_expires_at) <= now
    ):
        native_session.revoked_at = now
        session.commit()
        raise InvalidNativeSession

    access_token, replacement_refresh_token = _new_tokens()
    replacement_hash = _digest(replacement_refresh_token)
    absolute_expiry = _aware(native_session.absolute_expires_at)
    token_row.consumed_at = now
    token_row.replaced_by_hash = replacement_hash
    native_session.access_token_hash = _digest(access_token)
    native_session.access_expires_at = _limited_access_expiry(now, settings, absolute_expiry)
    native_session.last_refresh_at = now
    native_session.idle_expires_at = min(
        now + timedelta(seconds=settings.native_session_idle_seconds), absolute_expiry
    )
    try:
        # Flush consumption before inserting the replacement so the partial
        # unique index never sees two unconsumed refresh rows for this session.
        session.flush()
        session.add(
            NativeRefreshToken(
                token_hash=replacement_hash,
                session_id=native_session.id,
                issued_at=now,
                expires_at=absolute_expiry,
            )
        )
        user = session.get(UserAccount, native_session.user_id)
        session.commit()
    except (IntegrityError, OperationalError) as exc:
        # On databases without effective row locks, a concurrent rotation can
        # lose the write race. Re-read after rollback and treat a consumed token
        # as reuse so there is still only one valid token family.
        session.rollback()
        latest = session.get(NativeRefreshToken, token_hash)
        if latest is not None and latest.consumed_at is not None:
            current_session = session.scalar(
                select(NativeAuthSession)
                .where(NativeAuthSession.id == latest.session_id)
                .with_for_update()
            )
            if current_session is not None and current_session.revoked_at is None:
                current_session.revoked_at = utc_now()
                session.add(
                    AuthEvent(
                        legacy_owner_id=1 if current_session.user.role == "owner" else None,
                        actor_id=current_session.user_id,
                        event_type="native_refresh_reuse_detected",
                    )
                )
                session.commit()
            raise RefreshTokenReused from exc
        raise InvalidNativeSession from exc
    return _token_response(user, native_session, access_token, replacement_refresh_token, now)


def logout_native_session(session: Session, refresh_token: str) -> None:
    token_row = session.get(NativeRefreshToken, _digest(refresh_token))
    if token_row is None:
        raise InvalidNativeSession
    native_session = session.scalar(
        select(NativeAuthSession)
        .where(NativeAuthSession.id == token_row.session_id)
        .with_for_update()
    )
    if native_session is None or native_session.revoked_at is not None:
        raise InvalidNativeSession
    native_session.revoked_at = utc_now()
    session.add(
        AuthEvent(
            legacy_owner_id=1 if native_session.user.role == "owner" else None,
            actor_id=native_session.user_id,
            event_type="native_logout",
        )
    )
    session.commit()


@router.post("/login")
def native_login(
    payload: NativeLoginRequest,
    request: Request,
    session: Session = Depends(get_session),
) -> dict:
    _require_secure_transport(request)
    try:
        return authenticate_native(
            session,
            payload.login_name,
            payload.password,
            request.app.state.settings,
            request.client.host if request.client else None,
        )
    except LoginTemporarilyLimited as exc:
        raise HTTPException(status_code=429, detail="Authentication temporarily unavailable.") from exc
    except InvalidCredentials as exc:
        raise HTTPException(status_code=401, detail="Invalid login name or password.") from exc


@router.post("/refresh")
def native_refresh(
    payload: NativeRefreshRequest,
    request: Request,
    session: Session = Depends(get_session),
) -> dict:
    _require_secure_transport(request)
    try:
        return refresh_native_session(session, payload.refresh_token, request.app.state.settings)
    except (InvalidNativeSession, RefreshTokenReused) as exc:
        raise HTTPException(status_code=401, detail="Invalid or expired session.") from exc


@router.post(
    "/logout",
    status_code=204,
    response_model=None,
    response_class=Response,
)
def native_logout(
    payload: NativeLogoutRequest,
    request: Request,
    session: Session = Depends(get_session),
) -> Response:
    _require_secure_transport(request)
    try:
        logout_native_session(session, payload.refresh_token)
    except InvalidNativeSession as exc:
        raise HTTPException(status_code=401, detail="Invalid or expired session.") from exc
    return Response(status_code=204)


@router.get("/me")
def native_me(context: AuthContext = Depends(get_current_auth)) -> dict:
    if context.transport != "bearer":
        raise HTTPException(status_code=401, detail="Native bearer authentication required.")
    native_session = context.session
    return {
        "id": context.user.id,
        "login_name": context.user.login_name,
        "role": _role_name(context.user),
        "session_idle_expires_at": _aware(native_session.idle_expires_at).isoformat(),
        "session_expires_at": _aware(native_session.absolute_expires_at).isoformat(),
        "access_expires_at": _aware(native_session.access_expires_at).isoformat(),
    }
