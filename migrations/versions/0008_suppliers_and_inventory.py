"""Add suppliers, goods receipts, stock movements, and inventory balances.

Revision ID: 0008_suppliers_and_inventory
Revises: 0007_native_auth_sessions
"""

from alembic import op
import sqlalchemy as sa

revision = "0008_suppliers_and_inventory"
down_revision = "0007_native_auth_sessions"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "suppliers",
        sa.Column("id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("name", sa.String(length=200), nullable=False),
        sa.Column("normalized_name", sa.String(length=200), nullable=False),
        sa.Column("contact_person", sa.String(length=160), nullable=True),
        sa.Column("phone", sa.String(length=64), nullable=True),
        sa.Column("email", sa.String(length=254), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("length(trim(name)) BETWEEN 1 AND 200", name="ck_suppliers_name_nonempty"),
        sa.CheckConstraint("length(normalized_name) BETWEEN 1 AND 200", name="ck_suppliers_normalized_name_nonempty"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("normalized_name", name="uq_suppliers_normalized_name"),
    )
    op.create_index("ix_suppliers_is_active_name", "suppliers", ["is_active", "name"])

    op.create_table(
        "goods_receipts",
        sa.Column("id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("supplier_id", sa.Uuid(as_uuid=True), nullable=True),
        sa.Column("unlisted_supplier_name", sa.String(length=200), nullable=True),
        sa.Column("delivery_note_reference", sa.String(length=120), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("idempotency_key", sa.String(length=128), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("received_by", sa.Integer(), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("length(idempotency_key) BETWEEN 1 AND 128", name="ck_goods_receipts_idempotency_key"),
        sa.CheckConstraint("length(request_hash) = 64", name="ck_goods_receipts_request_hash"),
        sa.CheckConstraint(
            "NOT (supplier_id IS NOT NULL AND unlisted_supplier_name IS NOT NULL)",
            name="ck_goods_receipts_supplier_exclusive",
        ),
        sa.ForeignKeyConstraint(["received_by"], ["users.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["supplier_id"], ["suppliers.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("idempotency_key", name="uq_goods_receipts_idempotency_key"),
    )
    op.create_index("ix_goods_receipts_received_at", "goods_receipts", ["received_at"])
    op.create_index("ix_goods_receipts_supplier_id", "goods_receipts", ["supplier_id"])

    op.create_table(
        "goods_receipt_lines",
        sa.Column("id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("receipt_id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("line_number", sa.Integer(), nullable=False),
        sa.Column("product_id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("quantity", sa.Numeric(precision=18, scale=4), nullable=False),
        sa.Column("unit_cost", sa.Numeric(precision=18, scale=4), nullable=False),
        sa.CheckConstraint("line_number >= 1", name="ck_goods_receipt_lines_line_number"),
        sa.CheckConstraint("quantity > 0", name="ck_goods_receipt_lines_quantity_positive"),
        sa.CheckConstraint("unit_cost >= 0", name="ck_goods_receipt_lines_unit_cost_nonnegative"),
        sa.ForeignKeyConstraint(["product_id"], ["products.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["receipt_id"], ["goods_receipts.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("receipt_id", "line_number", name="uq_goods_receipt_lines_order"),
    )
    op.create_index("ix_goods_receipt_lines_product_id", "goods_receipt_lines", ["product_id"])
    op.create_index("ix_goods_receipt_lines_receipt_id", "goods_receipt_lines", ["receipt_id"])

    op.create_table(
        "stock_movements",
        sa.Column("id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("product_id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("movement_type", sa.String(length=24), nullable=False),
        sa.Column("quantity_delta", sa.Numeric(precision=18, scale=4), nullable=False),
        sa.Column("source_type", sa.String(length=32), nullable=False),
        sa.Column("source_id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("source_reference", sa.String(length=160), nullable=True),
        sa.Column("reason", sa.Text(), nullable=True),
        sa.Column("actor_id", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("movement_type IN ('receipt', 'adjustment', 'sale')", name="ck_stock_movements_type"),
        sa.CheckConstraint("quantity_delta <> 0", name="ck_stock_movements_nonzero_delta"),
        sa.CheckConstraint(
            "source_type IN ('goods_receipt', 'stock_adjustment', 'sale')",
            name="ck_stock_movements_source_type",
        ),
        sa.CheckConstraint(
            "movement_type <> 'adjustment' OR (reason IS NOT NULL AND length(trim(reason)) > 0)",
            name="ck_stock_movements_adjustment_reason",
        ),
        sa.ForeignKeyConstraint(["actor_id"], ["users.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["product_id"], ["products.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_stock_movements_product_created", "stock_movements", ["product_id", "created_at"])
    op.create_index("ix_stock_movements_source", "stock_movements", ["source_type", "source_id"])

    op.create_table(
        "inventory_balances",
        sa.Column("product_id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("quantity_on_hand", sa.Numeric(precision=18, scale=4), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("quantity_on_hand >= 0", name="ck_inventory_balances_nonnegative"),
        sa.ForeignKeyConstraint(["product_id"], ["products.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("product_id"),
    )


def downgrade() -> None:
    op.drop_table("inventory_balances")
    op.drop_index("ix_stock_movements_source", table_name="stock_movements")
    op.drop_index("ix_stock_movements_product_created", table_name="stock_movements")
    op.drop_table("stock_movements")
    op.drop_index("ix_goods_receipt_lines_receipt_id", table_name="goods_receipt_lines")
    op.drop_index("ix_goods_receipt_lines_product_id", table_name="goods_receipt_lines")
    op.drop_table("goods_receipt_lines")
    op.drop_index("ix_goods_receipts_supplier_id", table_name="goods_receipts")
    op.drop_index("ix_goods_receipts_received_at", table_name="goods_receipts")
    op.drop_table("goods_receipts")
    op.drop_index("ix_suppliers_is_active_name", table_name="suppliers")
    op.drop_table("suppliers")
