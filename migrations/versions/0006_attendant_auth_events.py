"""Allow owner auditing of attendant account administration.

Revision ID: 0006_attendant_auth_events
Revises: 0005_product_catalogue
"""

from alembic import op
import sqlalchemy as sa

revision = "0006_attendant_auth_events"
down_revision = "0005_product_catalogue"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("auth_events") as batch:
        batch.drop_constraint("ck_auth_events_event_type", type_="check")
        batch.create_check_constraint(
            "ck_auth_events_event_type",
            "event_type IN ('owner_provisioned', 'login_succeeded', 'login_failed', "
            "'login_limited', 'logout', 'attendant_created', 'attendant_status_changed')",
        )


def downgrade() -> None:
    connection = op.get_bind()
    incompatible_events = connection.execute(
        sa.text(
            "SELECT event_type, COUNT(*) FROM auth_events "
            "WHERE event_type IN ('attendant_created', 'attendant_status_changed') "
            "GROUP BY event_type ORDER BY event_type"
        )
    ).all()
    if incompatible_events:
        event_summary = ", ".join(
            f"{event_type}={count}" for event_type, count in incompatible_events
        )
        raise RuntimeError(
            "Cannot downgrade 0006_attendant_auth_events: the prior schema cannot represent "
            f"attendant audit events ({event_summary}); all audit records are preserved and "
            "no schema changes were applied."
        )

    with op.batch_alter_table("auth_events") as batch:
        batch.drop_constraint("ck_auth_events_event_type", type_="check")
        batch.create_check_constraint(
            "ck_auth_events_event_type",
            "event_type IN ('owner_provisioned', 'login_succeeded', 'login_failed', "
            "'login_limited', 'logout')",
        )
