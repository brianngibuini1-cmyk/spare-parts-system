"""Create owner authentication and server-side session tables.

Revision ID: 0002_owner_authentication
Revises: 0001_foundation
"""

from alembic import op
import sqlalchemy as sa

revision = "0002_owner_authentication"
down_revision = "0001_foundation"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "owner_accounts",
        sa.Column("id", sa.SmallInteger(), nullable=False),
        sa.Column("login_name", sa.String(length=254), nullable=False),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("id = 1", name="ck_owner_accounts_singleton_id"),
        sa.CheckConstraint("length(login_name) BETWEEN 1 AND 254", name="ck_owner_login_length"),
        sa.CheckConstraint("length(password_hash) > 0", name="ck_owner_password_hash_present"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("login_name", name="uq_owner_accounts_login_name"),
    )
    op.create_table(
        "auth_sessions",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("owner_id", sa.SmallInteger(), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("csrf_token_hash", sa.String(length=64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("idle_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("absolute_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("length(token_hash) = 64", name="ck_auth_sessions_token_hash_length"),
        sa.CheckConstraint("length(csrf_token_hash) = 64", name="ck_auth_sessions_csrf_hash_length"),
        sa.CheckConstraint("idle_expires_at <= absolute_expires_at", name="ck_auth_sessions_expiry_order"),
        sa.ForeignKeyConstraint(["owner_id"], ["owner_accounts.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("token_hash", name="uq_auth_sessions_token_hash"),
    )
    op.create_index("ix_auth_sessions_owner_id", "auth_sessions", ["owner_id"])
    op.create_index("ix_auth_sessions_idle_expires_at", "auth_sessions", ["idle_expires_at"])
    op.create_table(
        "login_throttles",
        sa.Column("login_digest", sa.String(length=64), nullable=False),
        sa.Column("window_started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("failed_attempts", sa.Integer(), nullable=False),
        sa.Column("locked_until", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("length(login_digest) = 64", name="ck_login_throttle_digest_length"),
        sa.CheckConstraint("failed_attempts >= 0", name="ck_login_throttle_failures_nonnegative"),
        sa.PrimaryKeyConstraint("login_digest"),
    )
    op.create_index("ix_login_throttles_locked_until", "login_throttles", ["locked_until"])
    op.create_table(
        "auth_events",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("owner_id", sa.SmallInteger(), nullable=True),
        sa.Column("event_type", sa.String(length=32), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "event_type IN ('owner_provisioned', 'login_succeeded', 'login_failed', 'login_limited', 'logout')",
            name="ck_auth_events_event_type",
        ),
        sa.ForeignKeyConstraint(["owner_id"], ["owner_accounts.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_auth_events_occurred_at", "auth_events", ["occurred_at"])


def downgrade() -> None:
    op.drop_index("ix_auth_events_occurred_at", table_name="auth_events")
    op.drop_table("auth_events")
    op.drop_index("ix_login_throttles_locked_until", table_name="login_throttles")
    op.drop_table("login_throttles")
    op.drop_index("ix_auth_sessions_idle_expires_at", table_name="auth_sessions")
    op.drop_index("ix_auth_sessions_owner_id", table_name="auth_sessions")
    op.drop_table("auth_sessions")
    op.drop_table("owner_accounts")
