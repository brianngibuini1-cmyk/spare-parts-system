"""Establish Alembic version tracking before business tables are approved."""

from typing import Sequence

revision: str = "0001_foundation"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Create no business tables; this is an empty foundation revision."""


def downgrade() -> None:
    """There is no application schema in this foundation revision."""
