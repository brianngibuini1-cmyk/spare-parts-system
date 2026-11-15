"""Shared, guarded database configuration for tests."""

from collections.abc import Iterator
import os

import pytest
from sqlalchemy import Engine, create_engine
from sqlalchemy.engine import make_url

from app.database import Base
import app.models  # noqa: F401 - register all mapped tables


@pytest.fixture
def test_database_url(tmp_path) -> Iterator[str]:
    """Use only an explicitly named test database; otherwise use isolated SQLite."""
    database_url = os.getenv("SPARE_PARTS_TEST_DATABASE_URL")
    if not database_url:
        if os.getenv("SPARE_PARTS_REQUIRE_POSTGRES_TESTS") == "true":
            raise RuntimeError("PostgreSQL tests are required but no test database URL is set.")
        database_url = f"sqlite:///{(tmp_path / 'application-test.db').as_posix()}"
    else:
        url = make_url(database_url)
        if (
            url.get_backend_name() != "postgresql"
            or not url.database
            or url.database != "spare_parts_test"
            or url.host not in {"localhost", "127.0.0.1", "::1"}
        ):
            raise RuntimeError(
                "SPARE_PARTS_TEST_DATABASE_URL must target local PostgreSQL database "
                "'spare_parts_test'."
            )
    engine: Engine = create_engine(database_url)
    try:
        Base.metadata.drop_all(engine)
        yield database_url
    finally:
        Base.metadata.drop_all(engine)
        engine.dispose()


@pytest.fixture
def migration_downgrade_database_url() -> Iterator[str]:
    """Provide a resettable, explicitly named disposable PostgreSQL test database."""
    database_url = os.getenv("SPARE_PARTS_DOWNGRADE_TEST_DATABASE_URL")
    if not database_url:
        if os.getenv("SPARE_PARTS_REQUIRE_POSTGRES_TESTS") == "true":
            raise RuntimeError("PostgreSQL migration downgrade test URL is required by CI.")
        pytest.skip("Migration downgrade integration tests require PostgreSQL.")

    url = make_url(database_url)
    if (
        url.get_backend_name() != "postgresql"
        or url.database != "spare_parts_downgrade_test"
        or url.host not in {"localhost", "127.0.0.1", "::1"}
    ):
        raise RuntimeError(
            "SPARE_PARTS_DOWNGRADE_TEST_DATABASE_URL must target local PostgreSQL database "
            "'spare_parts_downgrade_test'."
        )

    engine = create_engine(database_url)
    try:
        with engine.begin() as connection:
            connection.exec_driver_sql("DROP SCHEMA public CASCADE")
            connection.exec_driver_sql("CREATE SCHEMA public")
        yield database_url
    finally:
        engine.dispose()
