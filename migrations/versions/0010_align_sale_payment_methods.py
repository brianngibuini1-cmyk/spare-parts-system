"""Align sale payment methods to cash and manual M-PESA."""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "0010_align_sale_payment_methods"
down_revision = "0009_sales_and_receipts"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("sales") as batch_op:
        batch_op.drop_constraint("ck_sales_payment_method", type_="check")
        batch_op.create_check_constraint(
            "ck_sales_payment_method",
            "payment_method IN ('cash', 'mpesa')",
        )


def downgrade() -> None:
    with op.batch_alter_table("sales") as batch_op:
        batch_op.drop_constraint("ck_sales_payment_method", type_="check")
        batch_op.create_check_constraint(
            "ck_sales_payment_method",
            "payment_method IN ('cash', 'card', 'bank_transfer', 'other')",
        )
