"""Key login throttles by client peer rather than account identifier.

Revision ID: 0003_client_login_throttling
Revises: 0002_owner_authentication
"""

from alembic import op
import sqlalchemy as sa

revision = "0003_client_login_throttling"
down_revision = "0002_owner_authentication"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Old keys were hashes of login names; they must not act as source-IP throttle keys.
    op.execute("DELETE FROM login_throttles")
    with op.batch_alter_table("login_throttles") as batch_op:
        batch_op.drop_constraint("ck_login_throttle_digest_length", type_="check")
        batch_op.alter_column(
            "login_digest",
            new_column_name="client_digest",
            existing_type=sa.String(length=64),
            existing_nullable=False,
        )
        batch_op.create_check_constraint(
            "ck_login_throttle_client_digest_length", "length(client_digest) = 64"
        )
    op.create_index(
        "ix_login_throttles_window_started_at", "login_throttles", ["window_started_at"]
    )


def downgrade() -> None:
    op.drop_index("ix_login_throttles_window_started_at", table_name="login_throttles")
    with op.batch_alter_table("login_throttles") as batch_op:
        batch_op.drop_constraint("ck_login_throttle_client_digest_length", type_="check")
        batch_op.alter_column(
            "client_digest",
            new_column_name="login_digest",
            existing_type=sa.String(length=64),
            existing_nullable=False,
        )
        batch_op.create_check_constraint(
            "ck_login_throttle_digest_length", "length(login_digest) = 64"
        )
