"""Add products with pending owner price approval and product audit history.

Revision ID: 0005_product_catalogue
Revises: 0004_named_user_roles
"""

from alembic import op
import sqlalchemy as sa

revision = "0005_product_catalogue"
down_revision = "0004_named_user_roles"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "products",
        sa.Column("id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("internal_reference", sa.String(length=40), nullable=False),
        sa.Column("name", sa.String(length=200), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("category", sa.String(length=100), nullable=True),
        sa.Column("manufacturer_part_number", sa.String(length=128), nullable=True),
        sa.Column("image_key", sa.String(length=64), nullable=True),
        sa.Column("image_media_type", sa.String(length=32), nullable=True),
        sa.Column("selling_price", sa.Numeric(precision=18, scale=4), nullable=True),
        sa.Column("approval_status", sa.String(length=16), nullable=False),
        sa.Column("submitted_by", sa.Integer(), nullable=False),
        sa.Column("submitted_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("approved_by", sa.Integer(), nullable=True),
        sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("rejection_reason", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "approval_status IN ('pending', 'approved', 'rejected')", name="ck_products_status"
        ),
        sa.CheckConstraint(
            "selling_price IS NULL OR selling_price >= 0", name="ck_products_price_nonnegative"
        ),
        sa.CheckConstraint(
            "(approval_status = 'pending' AND selling_price IS NULL AND approved_by IS NULL "
            "AND approved_at IS NULL AND rejection_reason IS NULL) OR "
            "(approval_status = 'approved' AND selling_price IS NOT NULL AND approved_by IS NOT NULL "
            "AND approved_at IS NOT NULL AND rejection_reason IS NULL) OR "
            "(approval_status = 'rejected' AND selling_price IS NULL AND approved_by IS NULL "
            "AND approved_at IS NULL AND rejection_reason IS NOT NULL AND length(rejection_reason) > 0)",
            name="ck_products_approval_state",
        ),
        sa.CheckConstraint(
            "image_media_type IS NULL OR image_media_type IN ('image/jpeg', 'image/png', 'image/webp')",
            name="ck_products_image_media_type",
        ),
        sa.ForeignKeyConstraint(["submitted_by"], ["users.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["approved_by"], ["users.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("internal_reference", name="uq_products_internal_reference"),
    )
    op.create_index("ix_products_approval_status", "products", ["approval_status"])
    op.create_index("ix_products_name", "products", ["name"])
    op.create_index("ix_products_manufacturer_part_number", "products", ["manufacturer_part_number"])
    op.create_index("ix_products_submitted_by", "products", ["submitted_by"])
    op.create_table(
        "product_events",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("product_id", sa.Uuid(as_uuid=True), nullable=False),
        sa.Column("actor_id", sa.Integer(), nullable=False),
        sa.Column("event_type", sa.String(length=24), nullable=False),
        sa.Column("detail", sa.Text(), nullable=True),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "event_type IN ('submitted', 'edited', 'approved', 'rejected', 'image_updated')",
            name="ck_product_events_type",
        ),
        sa.ForeignKeyConstraint(["product_id"], ["products.id"], ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["actor_id"], ["users.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_product_events_product_occurred", "product_events", ["product_id", "occurred_at"])


def downgrade() -> None:
    op.drop_index("ix_product_events_product_occurred", table_name="product_events")
    op.drop_table("product_events")
    op.drop_index("ix_products_submitted_by", table_name="products")
    op.drop_index("ix_products_manufacturer_part_number", table_name="products")
    op.drop_index("ix_products_name", table_name="products")
    op.drop_index("ix_products_approval_status", table_name="products")
    op.drop_table("products")
