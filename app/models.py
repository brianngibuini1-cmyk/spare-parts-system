"""Authentication persistence models."""

from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID, uuid4

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    String,
    text,
    Text,
    UniqueConstraint,
    Numeric,
    Uuid,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


def utc_now() -> datetime:
    return datetime.now(UTC)


class OwnerAccount(Base):
    """The single initial owner account; bootstrap enforces its singleton key."""

    __tablename__ = "owner_accounts"
    __table_args__ = (
        CheckConstraint("id = 1", name="ck_owner_accounts_singleton_id"),
        CheckConstraint("length(login_name) BETWEEN 1 AND 254", name="ck_owner_login_length"),
        CheckConstraint("length(password_hash) > 0", name="ck_owner_password_hash_present"),
        UniqueConstraint("login_name", name="uq_owner_accounts_login_name"),
    )

    id: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    login_name: Mapped[str] = mapped_column(String(254), nullable=False)
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)



class UserAccount(Base):
    """Unified named owner and attendant identity used for authorization and audit."""

    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint("role IN ('owner', 'attendant')", name="ck_users_role"),
        CheckConstraint("length(login_name) BETWEEN 1 AND 254", name="ck_users_login_length"),
        CheckConstraint("length(password_hash) > 0", name="ck_users_password_hash_present"),
        UniqueConstraint("login_name", name="uq_users_login_name"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    login_name: Mapped[str] = mapped_column(String(254), nullable=False)
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    role: Mapped[str] = mapped_column(String(16), nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)
    sessions: Mapped[list["AuthSession"]] = relationship(back_populates="user")


class AuthSession(Base):
    """Opaque server-side session; only hashes of browser tokens are stored."""

    __tablename__ = "auth_sessions"
    __table_args__ = (
        UniqueConstraint("token_hash", name="uq_auth_sessions_token_hash"),
        CheckConstraint("length(token_hash) = 64", name="ck_auth_sessions_token_hash_length"),
        CheckConstraint("length(csrf_token_hash) = 64", name="ck_auth_sessions_csrf_hash_length"),
        CheckConstraint("idle_expires_at <= absolute_expires_at", name="ck_auth_sessions_expiry_order"),
        Index("ix_auth_sessions_owner_id", "owner_id"),
        Index("ix_auth_sessions_user_id", "user_id"),
        Index("ix_auth_sessions_idle_expires_at", "idle_expires_at"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    legacy_owner_id: Mapped[int | None] = mapped_column(
        "owner_id", SmallInteger, ForeignKey("owner_accounts.id", ondelete="CASCADE"), nullable=True
    )
    user_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    csrf_token_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    idle_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    absolute_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    user: Mapped[UserAccount] = relationship(back_populates="sessions")


class NativeAuthSession(Base):
    """Revocable native-client session with a replaceable hashed access token."""

    __tablename__ = "native_auth_sessions"
    __table_args__ = (
        UniqueConstraint("access_token_hash", name="uq_native_auth_sessions_access_hash"),
        CheckConstraint("length(access_token_hash) = 64", name="ck_native_auth_access_hash_length"),
        CheckConstraint("idle_expires_at <= absolute_expires_at", name="ck_native_auth_expiry_order"),
        CheckConstraint("access_expires_at <= absolute_expires_at", name="ck_native_auth_access_expiry_order"),
        Index("ix_native_auth_sessions_user_id", "user_id"),
        Index("ix_native_auth_sessions_idle_expires_at", "idle_expires_at"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    access_token_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_refresh_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    idle_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    absolute_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    access_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    user: Mapped[UserAccount] = relationship()
    refresh_tokens: Mapped[list["NativeRefreshToken"]] = relationship(
        back_populates="auth_session", cascade="all, delete-orphan"
    )


class NativeRefreshToken(Base):
    """Hashed refresh-token history retained for atomic rotation/reuse detection."""

    __tablename__ = "native_refresh_tokens"
    __table_args__ = (
        CheckConstraint("length(token_hash) = 64", name="ck_native_refresh_token_hash_length"),
        CheckConstraint(
            "replaced_by_hash IS NULL OR length(replaced_by_hash) = 64",
            name="ck_native_refresh_replacement_hash_length",
        ),
        CheckConstraint(
            "(consumed_at IS NULL AND replaced_by_hash IS NULL) OR "
            "(consumed_at IS NOT NULL AND replaced_by_hash IS NOT NULL)",
            name="ck_native_refresh_consumption_state",
        ),
        Index("ix_native_refresh_tokens_session_id", "session_id"),
        Index("ix_native_refresh_tokens_expires_at", "expires_at"),
        Index(
            "uq_native_refresh_tokens_one_active_per_session",
            "session_id",
            unique=True,
            postgresql_where=text("consumed_at IS NULL"),
            sqlite_where=text("consumed_at IS NULL"),
        ),
    )

    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    session_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("native_auth_sessions.id", ondelete="CASCADE"), nullable=False
    )
    issued_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    replaced_by_hash: Mapped[str | None] = mapped_column(String(64))
    auth_session: Mapped[NativeAuthSession] = relationship(back_populates="refresh_tokens")


class LoginThrottle(Base):
    """Persistent per-client throttling state without storing raw client addresses."""

    __tablename__ = "login_throttles"
    __table_args__ = (
        CheckConstraint("length(client_digest) = 64", name="ck_login_throttle_client_digest_length"),
        CheckConstraint("failed_attempts >= 0", name="ck_login_throttle_failures_nonnegative"),
        Index("ix_login_throttles_locked_until", "locked_until"),
        Index("ix_login_throttles_window_started_at", "window_started_at"),
    )

    client_digest: Mapped[str] = mapped_column(String(64), primary_key=True)
    window_started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    failed_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    locked_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class AuthEvent(Base):
    """Minimal authentication audit event; never records passwords or tokens."""

    __tablename__ = "auth_events"
    __table_args__ = (
        CheckConstraint(
            "event_type IN ('owner_provisioned', 'login_succeeded', 'login_failed', "
            "'login_limited', 'logout', 'attendant_created', 'attendant_status_changed', "
            "'native_login_succeeded', 'native_refresh_reuse_detected', 'native_logout')",
            name="ck_auth_events_event_type",
        ),
        Index("ix_auth_events_occurred_at", "occurred_at"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    legacy_owner_id: Mapped[int | None] = mapped_column(
        "owner_id",
        SmallInteger, ForeignKey("owner_accounts.id", ondelete="SET NULL")
    )
    actor_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("users.id", ondelete="SET NULL"))
    event_type: Mapped[str] = mapped_column(String(32), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)


def new_product_uuid() -> UUID:
    return uuid4()


class Product(Base):
    """Product submission and owner-approved sale price; stock is intentionally absent."""

    __tablename__ = "products"
    __table_args__ = (
        CheckConstraint("approval_status IN ('pending', 'approved', 'rejected')", name="ck_products_status"),
        CheckConstraint("selling_price IS NULL OR selling_price >= 0", name="ck_products_price_nonnegative"),
        CheckConstraint(
            "(approval_status = 'pending' AND selling_price IS NULL AND approved_by IS NULL "
            "AND approved_at IS NULL AND rejection_reason IS NULL) OR "
            "(approval_status = 'approved' AND selling_price IS NOT NULL AND approved_by IS NOT NULL "
            "AND approved_at IS NOT NULL AND rejection_reason IS NULL) OR "
            "(approval_status = 'rejected' AND selling_price IS NULL AND approved_by IS NULL "
            "AND approved_at IS NULL AND rejection_reason IS NOT NULL AND length(rejection_reason) > 0)",
            name="ck_products_approval_state",
        ),
        CheckConstraint(
            "image_media_type IS NULL OR image_media_type IN "
            "('image/jpeg', 'image/png', 'image/webp')",
            name="ck_products_image_media_type",
        ),
        UniqueConstraint("internal_reference", name="uq_products_internal_reference"),
        Index("ix_products_approval_status", "approval_status"),
        Index("ix_products_name", "name"),
        Index("ix_products_manufacturer_part_number", "manufacturer_part_number"),
        Index("ix_products_submitted_by", "submitted_by"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=new_product_uuid)
    internal_reference: Mapped[str] = mapped_column(String(40), nullable=False)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    description: Mapped[str | None] = mapped_column(Text)
    category: Mapped[str | None] = mapped_column(String(100))
    manufacturer_part_number: Mapped[str | None] = mapped_column(String(128))
    image_key: Mapped[str | None] = mapped_column(String(64))
    image_media_type: Mapped[str | None] = mapped_column(String(32))
    selling_price: Mapped[Decimal | None] = mapped_column(Numeric(18, 4))
    approval_status: Mapped[str] = mapped_column(String(16), nullable=False, default="pending")
    submitted_by: Mapped[int] = mapped_column(Integer, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False)
    submitted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)
    approved_by: Mapped[int | None] = mapped_column(Integer, ForeignKey("users.id", ondelete="RESTRICT"))
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    rejection_reason: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)
    submitter: Mapped[UserAccount] = relationship(foreign_keys=[submitted_by])
    approver: Mapped[UserAccount | None] = relationship(foreign_keys=[approved_by])


class ProductEvent(Base):
    """Append-only application history of product submission and approval actions."""

    __tablename__ = "product_events"
    __table_args__ = (
        CheckConstraint(
            "event_type IN ('submitted', 'edited', 'approved', 'rejected', 'image_updated')",
            name="ck_product_events_type",
        ),
        Index("ix_product_events_product_occurred", "product_id", "occurred_at"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    product_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), ForeignKey("products.id", ondelete="RESTRICT"), nullable=False)
    actor_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False)
    event_type: Mapped[str] = mapped_column(String(24), nullable=False)
    detail: Mapped[str | None] = mapped_column(Text)
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)
