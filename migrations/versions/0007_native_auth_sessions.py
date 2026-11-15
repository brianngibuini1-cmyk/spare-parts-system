"""Add revocable native access sessions and rotating refresh-token history.

Revision ID: 0007_native_auth_sessions
Revises: 0006_attendant_auth_events
"""

from alembic import op
import sqlalchemy as sa

revision = "0007_native_auth_sessions"
down_revision = "0006_attendant_auth_events"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "native_auth_sessions",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("access_token_hash", sa.String(length=64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_refresh_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("idle_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("absolute_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("access_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("length(access_token_hash) = 64", name="ck_native_auth_access_hash_length"),
        sa.CheckConstraint(
            "idle_expires_at <= absolute_expires_at", name="ck_native_auth_expiry_order"
        ),
        sa.CheckConstraint(
            "access_expires_at <= absolute_expires_at", name="ck_native_auth_access_expiry_order"
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("access_token_hash", name="uq_native_auth_sessions_access_hash"),
    )
    op.create_index("ix_native_auth_sessions_user_id", "native_auth_sessions", ["user_id"])
    op.create_index(
        "ix_native_auth_sessions_idle_expires_at", "native_auth_sessions", ["idle_expires_at"]
    )

    op.create_table(
        "native_refresh_tokens",
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("session_id", sa.Integer(), nullable=False),
        sa.Column("issued_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("replaced_by_hash", sa.String(length=64), nullable=True),
        sa.CheckConstraint(
            "length(token_hash) = 64", name="ck_native_refresh_token_hash_length"
        ),
        sa.CheckConstraint(
            "replaced_by_hash IS NULL OR length(replaced_by_hash) = 64",
            name="ck_native_refresh_replacement_hash_length",
        ),
        sa.CheckConstraint(
            "(consumed_at IS NULL AND replaced_by_hash IS NULL) OR "
            "(consumed_at IS NOT NULL AND replaced_by_hash IS NOT NULL)",
            name="ck_native_refresh_consumption_state",
        ),
        sa.ForeignKeyConstraint(
            ["session_id"], ["native_auth_sessions.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("token_hash"),
    )
    op.create_index(
        "ix_native_refresh_tokens_session_id", "native_refresh_tokens", ["session_id"]
    )
    op.create_index(
        "ix_native_refresh_tokens_expires_at", "native_refresh_tokens", ["expires_at"]
    )
    op.create_index(
        "uq_native_refresh_tokens_one_active_per_session",
        "native_refresh_tokens",
        ["session_id"],
        unique=True,
        postgresql_where=sa.text("consumed_at IS NULL"),
        sqlite_where=sa.text("consumed_at IS NULL"),
    )

    with op.batch_alter_table("auth_events") as batch:
        batch.drop_constraint("ck_auth_events_event_type", type_="check")
        batch.create_check_constraint(
            "ck_auth_events_event_type",
            "event_type IN ('owner_provisioned', 'login_succeeded', 'login_failed', "
            "'login_limited', 'logout', 'attendant_created', 'attendant_status_changed', "
            "'native_login_succeeded', 'native_refresh_reuse_detected', 'native_logout')",
        )


def downgrade() -> None:
    connection = op.get_bind()
    native_sessions = connection.execute(
        sa.text("SELECT COUNT(*) FROM native_auth_sessions")
    ).scalar_one()
    native_refresh_tokens = connection.execute(
        sa.text("SELECT COUNT(*) FROM native_refresh_tokens")
    ).scalar_one()
    native_events = connection.execute(
        sa.text(
            "SELECT event_type, COUNT(*) FROM auth_events WHERE event_type IN "
            "('native_login_succeeded', 'native_refresh_reuse_detected', 'native_logout') "
            "GROUP BY event_type ORDER BY event_type"
        )
    ).all()
    if native_sessions or native_refresh_tokens or native_events:
        event_summary = ", ".join(
            f"{event_type}={count}" for event_type, count in native_events
        )
        raise RuntimeError(
            "Cannot downgrade 0007_native_auth_sessions: the prior schema cannot represent "
            "native session/refresh rows or native authentication events "
            f"(sessions={native_sessions}, refresh tokens={native_refresh_tokens}, "
            f"events=[{event_summary}]); all records are preserved and no schema changes "
            "were applied."
        )

    with op.batch_alter_table("auth_events") as batch:
        batch.drop_constraint("ck_auth_events_event_type", type_="check")
        batch.create_check_constraint(
            "ck_auth_events_event_type",
            "event_type IN ('owner_provisioned', 'login_succeeded', 'login_failed', "
            "'login_limited', 'logout', 'attendant_created', 'attendant_status_changed')",
        )
    op.drop_index("uq_native_refresh_tokens_one_active_per_session", table_name="native_refresh_tokens")
    op.drop_index("ix_native_refresh_tokens_expires_at", table_name="native_refresh_tokens")
    op.drop_index("ix_native_refresh_tokens_session_id", table_name="native_refresh_tokens")
    op.drop_table("native_refresh_tokens")
    op.drop_index("ix_native_auth_sessions_idle_expires_at", table_name="native_auth_sessions")
    op.drop_index("ix_native_auth_sessions_user_id", table_name="native_auth_sessions")
    op.drop_table("native_auth_sessions")
