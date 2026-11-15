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


class Supplier(Base):
    """Supplier directory record; deactivated rather than hard-deleted once referenced."""

    __tablename__ = "suppliers"
    __table_args__ = (
        UniqueConstraint("normalized_name", name="uq_suppliers_normalized_name"),
        CheckConstraint("length(trim(name)) BETWEEN 1 AND 200", name="ck_suppliers_name_nonempty"),
        CheckConstraint("length(normalized_name) BETWEEN 1 AND 200", name="ck_suppliers_normalized_name_nonempty"),
        Index("ix_suppliers_is_active_name", "is_active", "name"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid4)
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(200), nullable=False)
    contact_person: Mapped[str | None] = mapped_column(String(160))
    phone: Mapped[str | None] = mapped_column(String(64))
    email: Mapped[str | None] = mapped_column(String(254))
    notes: Mapped[str | None] = mapped_column(Text)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utc_now, onupdate=utc_now
    )


class GoodsReceipt(Base):
    """Posted incoming stock receipt document; immutable once recorded."""

    __tablename__ = "goods_receipts"
    __table_args__ = (
        UniqueConstraint("idempotency_key", name="uq_goods_receipts_idempotency_key"),
        CheckConstraint("length(idempotency_key) BETWEEN 1 AND 128", name="ck_goods_receipts_idempotency_key"),
        CheckConstraint("length(request_hash) = 64", name="ck_goods_receipts_request_hash"),
        CheckConstraint(
            "NOT (supplier_id IS NOT NULL AND unlisted_supplier_name IS NOT NULL)",
            name="ck_goods_receipts_supplier_exclusive",
        ),
        Index("ix_goods_receipts_received_at", "received_at"),
        Index("ix_goods_receipts_supplier_id", "supplier_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid4)
    supplier_id: Mapped[UUID | None] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("suppliers.id", ondelete="RESTRICT"), nullable=True
    )
    unlisted_supplier_name: Mapped[str | None] = mapped_column(String(200), nullable=True)
    delivery_note_reference: Mapped[str | None] = mapped_column(String(120), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    received_by: Mapped[int] = mapped_column(Integer, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)

    supplier: Mapped[Supplier | None] = relationship(foreign_keys=[supplier_id])
    receiver: Mapped[UserAccount] = relationship(foreign_keys=[received_by])
    lines: Mapped[list["GoodsReceiptLine"]] = relationship(
        back_populates="receipt", order_by="GoodsReceiptLine.line_number"
    )


class GoodsReceiptLine(Base):
    """Line item belonging to a posted goods receipt."""

    __tablename__ = "goods_receipt_lines"
    __table_args__ = (
        UniqueConstraint("receipt_id", "line_number", name="uq_goods_receipt_lines_order"),
        CheckConstraint("line_number >= 1", name="ck_goods_receipt_lines_line_number"),
        CheckConstraint("quantity > 0", name="ck_goods_receipt_lines_quantity_positive"),
        CheckConstraint("unit_cost >= 0", name="ck_goods_receipt_lines_unit_cost_nonnegative"),
        Index("ix_goods_receipt_lines_receipt_id", "receipt_id"),
        Index("ix_goods_receipt_lines_product_id", "product_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid4)
    receipt_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("goods_receipts.id", ondelete="RESTRICT"), nullable=False
    )
    line_number: Mapped[int] = mapped_column(Integer, nullable=False)
    product_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("products.id", ondelete="RESTRICT"), nullable=False
    )
    quantity: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)
    unit_cost: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)

    receipt: Mapped[GoodsReceipt] = relationship(back_populates="lines")
    product: Mapped[Product] = relationship(foreign_keys=[product_id])


class StockMovement(Base):
    """Append-only stock movement ledger; authoritative source of quantity changes."""

    __tablename__ = "stock_movements"
    __table_args__ = (
        CheckConstraint("movement_type IN ('receipt', 'adjustment', 'sale')", name="ck_stock_movements_type"),
        CheckConstraint("quantity_delta <> 0", name="ck_stock_movements_nonzero_delta"),
        CheckConstraint(
            "source_type IN ('goods_receipt', 'stock_adjustment', 'sale')",
            name="ck_stock_movements_source_type",
        ),
        CheckConstraint(
            "movement_type <> 'adjustment' OR (reason IS NOT NULL AND length(trim(reason)) > 0)",
            name="ck_stock_movements_adjustment_reason",
        ),
        Index("ix_stock_movements_product_created", "product_id", "created_at"),
        Index("ix_stock_movements_source", "source_type", "source_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid4)
    product_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("products.id", ondelete="RESTRICT"), nullable=False
    )
    movement_type: Mapped[str] = mapped_column(String(24), nullable=False)
    quantity_delta: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)
    source_type: Mapped[str] = mapped_column(String(32), nullable=False)
    source_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    source_reference: Mapped[str | None] = mapped_column(String(160), nullable=True)
    reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    actor_id: Mapped[int] = mapped_column(Integer, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)

    product: Mapped[Product] = relationship(foreign_keys=[product_id])
    actor: Mapped[UserAccount] = relationship(foreign_keys=[actor_id])


class InventoryBalance(Base):
    """Transactional stock balance cache per product; never negative."""

    __tablename__ = "inventory_balances"
    __table_args__ = (
        CheckConstraint("quantity_on_hand >= 0", name="ck_inventory_balances_nonnegative"),
    )

    product_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("products.id", ondelete="RESTRICT"), primary_key=True
    )
    quantity_on_hand: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False, default=Decimal("0.0000"))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)

    product: Mapped[Product] = relationship(foreign_keys=[product_id])


class Sale(Base):
    """Completed sale and payment record; immutable once posted."""

    __tablename__ = "sales"
    __table_args__ = (
        UniqueConstraint("receipt_number", name="uq_sales_receipt_number"),
        UniqueConstraint("idempotency_key", name="uq_sales_idempotency_key"),
        CheckConstraint("length(receipt_number) BETWEEN 1 AND 64", name="ck_sales_receipt_number"),
        CheckConstraint("length(idempotency_key) BETWEEN 1 AND 128", name="ck_sales_idempotency_key"),
        CheckConstraint("length(request_hash) = 64", name="ck_sales_request_hash"),
        CheckConstraint("status IN ('completed')", name="ck_sales_status"),
        CheckConstraint("total_amount >= 0", name="ck_sales_total_nonnegative"),
        CheckConstraint(
            "payment_method IN ('cash', 'mpesa')",
            name="ck_sales_payment_method",
        ),
        CheckConstraint("amount_tendered >= total_amount", name="ck_sales_amount_tendered_sufficient"),
        CheckConstraint("change_given >= 0", name="ck_sales_change_nonnegative"),
        Index("ix_sales_sold_at", "sold_at"),
        Index("ix_sales_sold_by", "sold_by"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid4)
    receipt_number: Mapped[str] = mapped_column(String(64), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(24), nullable=False, default="completed")
    total_amount: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)
    payment_method: Mapped[str] = mapped_column(String(32), nullable=False)
    amount_tendered: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)
    change_given: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)
    payment_reference: Mapped[str | None] = mapped_column(String(120), nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    sold_by: Mapped[int] = mapped_column(Integer, ForeignKey("users.id", ondelete="RESTRICT"), nullable=False)
    sold_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, default=utc_now)

    seller: Mapped[UserAccount] = relationship(foreign_keys=[sold_by])
    lines: Mapped[list["SaleLine"]] = relationship(
        back_populates="sale", order_by="SaleLine.line_number"
    )


class SaleLine(Base):
    """Sale line with historical product and price snapshots at the time of sale."""

    __tablename__ = "sale_lines"
    __table_args__ = (
        UniqueConstraint("sale_id", "line_number", name="uq_sale_lines_order"),
        UniqueConstraint("sale_id", "product_id", name="uq_sale_lines_product"),
        CheckConstraint("line_number >= 1", name="ck_sale_lines_line_number"),
        CheckConstraint("quantity > 0", name="ck_sale_lines_quantity_positive"),
        CheckConstraint("unit_price >= 0", name="ck_sale_lines_unit_price_nonnegative"),
        CheckConstraint("line_total >= 0", name="ck_sale_lines_total_nonnegative"),
        Index("ix_sale_lines_sale_id", "sale_id"),
        Index("ix_sale_lines_product_id", "product_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), primary_key=True, default=uuid4)
    sale_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("sales.id", ondelete="RESTRICT"), nullable=False
    )
    line_number: Mapped[int] = mapped_column(Integer, nullable=False)
    product_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("products.id", ondelete="RESTRICT"), nullable=False
    )
    product_internal_reference: Mapped[str] = mapped_column(String(64), nullable=False)
    product_name: Mapped[str] = mapped_column(String(200), nullable=False)
    product_description: Mapped[str | None] = mapped_column(Text, nullable=True)
    manufacturer_part_number: Mapped[str | None] = mapped_column(String(120), nullable=True)
    unit_price: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)
    quantity: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)
    line_total: Mapped[Decimal] = mapped_column(Numeric(18, 4), nullable=False)

    sale: Mapped[Sale] = relationship(back_populates="lines")
    product: Mapped[Product] = relationship(foreign_keys=[product_id])
