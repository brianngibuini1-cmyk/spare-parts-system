"""Add sales and sale_lines tables for completed sales and digital receipts.

Revision ID: 0009_sales_and_receipts
Revises: 0008_suppliers_and_inventory
"""

from alembic import op
import sqlalchemy as sa

revision = "0009_sales_and_receipts"
down_revision = "0008_suppliers_and_inventory"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "sales",
        sa.Column("id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("receipt_number", sa.String(length=64), nullable=False),
        sa.Column("idempotency_key", sa.String(length=128), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=24), nullable=False),
        sa.Column("total_amount", sa.Numeric(precision=18, scale=4), nullable=False),
        sa.Column("payment_method", sa.String(length=32), nullable=False),
        sa.Column("amount_tendered", sa.Numeric(precision=18, scale=4), nullable=False),
        sa.Column("change_given", sa.Numeric(precision=18, scale=4), nullable=False),
        sa.Column("payment_reference", sa.String(length=120), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("sold_by", sa.Integer(), nullable=False),
        sa.Column("sold_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("length(receipt_number) BETWEEN 1 AND 64", name="ck_sales_receipt_number"),
        sa.CheckConstraint("length(idempotency_key) BETWEEN 1 AND 128", name="ck_sales_idempotency_key"),
        sa.CheckConstraint("length(request_hash) = 64", name="ck_sales_request_hash"),
        sa.CheckConstraint("status IN ('completed')", name="ck_sales_status"),
        sa.CheckConstraint("total_amount >= 0", name="ck_sales_total_nonnegative"),
        sa.CheckConstraint(
            "payment_method IN ('cash', 'card', 'bank_transfer', 'other')",
            name="ck_sales_payment_method",
        ),
        sa.CheckConstraint("amount_tendered >= total_amount", name="ck_sales_amount_tendered_sufficient"),
        sa.CheckConstraint("change_given >= 0", name="ck_sales_change_nonnegative"),
        sa.ForeignKeyConstraint(["sold_by"], ["users.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("idempotency_key", name="uq_sales_idempotency_key"),
        sa.UniqueConstraint("receipt_number", name="uq_sales_receipt_number"),
    )
    op.create_index("ix_sales_sold_at", "sales", ["sold_at"])
    op.create_index("ix_sales_sold_by", "sales", ["sold_by"])

    op.create_table(
        "sale_lines",
        sa.Column("id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("sale_id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("line_number", sa.Integer(), nullable=False),
        sa.Column("product_id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("product_internal_reference", sa.String(length=64), nullable=False),
        sa.Column("product_name", sa.String(length=200), nullable=False),
        sa.Column("product_description", sa.Text(), nullable=True),
        sa.Column("manufacturer_part_number", sa.String(length=120), nullable=True),
        sa.Column("unit_price", sa.Numeric(precision=18, scale=4), nullable=False),
        sa.Column("quantity", sa.Numeric(precision=18, scale=4), nullable=False),
        sa.Column("line_total", sa.Numeric(precision=18, scale=4), nullable=False),
        sa.CheckConstraint("line_number >= 1", name="ck_sale_lines_line_number"),
        sa.CheckConstraint("quantity > 0", name="ck_sale_lines_quantity_positive"),
        sa.CheckConstraint("unit_price >= 0", name="ck_sale_lines_unit_price_nonnegative"),
        sa.CheckConstraint("line_total >= 0", name="ck_sale_lines_total_nonnegative"),
        sa.ForeignKeyConstraint(["product_id"], ["products.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["sale_id"], ["sales.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("sale_id", "line_number", name="uq_sale_lines_order"),
        sa.UniqueConstraint("sale_id", "product_id", name="uq_sale_lines_product"),
    )
    op.create_index("ix_sale_lines_product_id", "sale_lines", ["product_id"])
    op.create_index("ix_sale_lines_sale_id", "sale_lines", ["sale_id"])


def downgrade() -> None:
    op.drop_index("ix_sale_lines_sale_id", table_name="sale_lines")
    op.drop_index("ix_sale_lines_product_id", table_name="sale_lines")
    op.drop_table("sale_lines")
    op.drop_index("ix_sales_sold_by", table_name="sales")
    op.drop_index("ix_sales_sold_at", table_name="sales")
    op.drop_table("sales")
