"""Add unified owner/attendant identities while preserving owner sessions.

Revision ID: 0004_named_user_roles
Revises: 0003_client_login_throttling
"""

from alembic import op
import sqlalchemy as sa

revision = "0004_named_user_roles"
down_revision = "0003_client_login_throttling"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("login_name", sa.String(length=254), nullable=False),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column("role", sa.String(length=16), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("role IN ('owner', 'attendant')", name="ck_users_role"),
        sa.CheckConstraint("length(login_name) BETWEEN 1 AND 254", name="ck_users_login_length"),
        sa.CheckConstraint("length(password_hash) > 0", name="ck_users_password_hash_present"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("login_name", name="uq_users_login_name"),
    )
    op.execute(
        sa.text(
            "INSERT INTO users (id, login_name, password_hash, role, is_active, created_at) "
            "SELECT id, login_name, password_hash, 'owner', is_active, created_at FROM owner_accounts"
        )
    )
    if op.get_bind().dialect.name == "postgresql":
        op.execute(
            "SELECT setval(pg_get_serial_sequence('users', 'id'), "
            "COALESCE((SELECT MAX(id) FROM users), 1), true)"
        )

    with op.batch_alter_table("auth_sessions") as batch:
        batch.add_column(sa.Column("user_id", sa.Integer(), nullable=True))
        batch.create_foreign_key(
            "fk_auth_sessions_user_id_users", "users", ["user_id"], ["id"], ondelete="CASCADE"
        )
    op.execute("UPDATE auth_sessions SET user_id = owner_id")
    with op.batch_alter_table("auth_sessions") as batch:
        batch.alter_column("user_id", existing_type=sa.Integer(), nullable=False)
        batch.alter_column("owner_id", existing_type=sa.SmallInteger(), nullable=True)
    op.create_index("ix_auth_sessions_user_id", "auth_sessions", ["user_id"])

    with op.batch_alter_table("auth_events") as batch:
        batch.add_column(sa.Column("actor_id", sa.Integer(), nullable=True))
        batch.create_foreign_key(
            "fk_auth_events_actor_id_users", "users", ["actor_id"], ["id"], ondelete="SET NULL"
        )
    op.execute("UPDATE auth_events SET actor_id = owner_id WHERE owner_id IS NOT NULL")


def downgrade() -> None:
    connection = op.get_bind()
    attendant_ids = connection.execute(
        sa.text("SELECT id FROM users WHERE role = 'attendant' ORDER BY id")
    ).scalars().all()
    if attendant_ids:
        raise RuntimeError(
            "Cannot downgrade 0004_named_user_roles: attendant account IDs "
            f"{attendant_ids} cannot be represented by the prior single-owner schema; "
            "all records are preserved and no schema changes were applied."
        )

    mismatched_owner_ids = connection.execute(
        sa.text(
            "SELECT u.id FROM users AS u LEFT JOIN owner_accounts AS o ON o.id = u.id "
            "WHERE u.role = 'owner' AND (o.id IS NULL OR u.login_name <> o.login_name "
            "OR u.password_hash <> o.password_hash OR u.is_active <> o.is_active "
            "OR u.created_at <> o.created_at) ORDER BY u.id"
        )
    ).scalars().all()
    missing_user_ids = connection.execute(
        sa.text(
            "SELECT o.id FROM owner_accounts AS o LEFT JOIN users AS u ON u.id = o.id "
            "WHERE u.id IS NULL ORDER BY o.id"
        )
    ).scalars().all()
    incompatible_session_ids = connection.execute(
        sa.text(
            "SELECT id FROM auth_sessions "
            "WHERE owner_id IS NULL OR owner_id <> user_id ORDER BY id"
        )
    ).scalars().all()
    incompatible_event_ids = connection.execute(
        sa.text(
            "SELECT id FROM auth_events "
            "WHERE actor_id IS NOT NULL AND (owner_id IS NULL OR actor_id <> owner_id) "
            "ORDER BY id"
        )
    ).scalars().all()
    if any(
        (mismatched_owner_ids, missing_user_ids, incompatible_session_ids, incompatible_event_ids)
    ):
        raise RuntimeError(
            "Cannot downgrade 0004_named_user_roles: owner identities, sessions, or audit "
            "actors differ from the prior owner-only representation "
            f"(mismatched owners={mismatched_owner_ids}, missing users={missing_user_ids}, "
            f"sessions={incompatible_session_ids}, events={incompatible_event_ids}); "
            "all records are preserved and no schema changes were applied."
        )

    with op.batch_alter_table("auth_events") as batch:
        batch.drop_column("actor_id")
    op.drop_index("ix_auth_sessions_user_id", table_name="auth_sessions")
    with op.batch_alter_table("auth_sessions") as batch:
        batch.drop_column("user_id")
        batch.alter_column("owner_id", existing_type=sa.SmallInteger(), nullable=False)
    op.drop_table("users")
