"""Assertions for the schema produced by the PostgreSQL migration job."""

import os

import pytest
from sqlalchemy import create_engine, inspect
from sqlalchemy.engine import make_url


def test_native_auth_schema_constraints_and_indexes():
    database_url = os.getenv("SPARE_PARTS_SCHEMA_TEST_DATABASE_URL")
    if not database_url:
        if os.getenv("SPARE_PARTS_REQUIRE_POSTGRES_TESTS") == "true":
            pytest.fail("PostgreSQL migration schema URL is required by CI.")
        pytest.skip("PostgreSQL migration schema is configured only by CI.")

    url = make_url(database_url)
    if (
        url.get_backend_name() != "postgresql"
        or not url.database
        or url.database != "spare_parts_schema_test"
        or url.host not in {"localhost", "127.0.0.1", "::1"}
    ):
        pytest.fail(
            "Schema test URL must target local PostgreSQL database 'spare_parts_schema_test'."
        )

    engine = create_engine(database_url)
    try:
        inspector = inspect(engine)
        assert {"native_auth_sessions", "native_refresh_tokens"}.issubset(
            inspector.get_table_names()
        )

        sessions = "native_auth_sessions"
        session_foreign_keys = inspector.get_foreign_keys(sessions)
        assert any(
            key["referred_table"] == "users" and key["constrained_columns"] == ["user_id"]
            for key in session_foreign_keys
        )
        session_uniques = {
            constraint["name"] for constraint in inspector.get_unique_constraints(sessions)
        }
        assert "uq_native_auth_sessions_access_hash" in session_uniques
        session_checks = {
            constraint["name"] for constraint in inspector.get_check_constraints(sessions)
        }
        assert {
            "ck_native_auth_access_hash_length",
            "ck_native_auth_expiry_order",
            "ck_native_auth_access_expiry_order",
        }.issubset(session_checks)
        assert {item["name"] for item in inspector.get_indexes(sessions)} >= {
            "ix_native_auth_sessions_user_id",
            "ix_native_auth_sessions_idle_expires_at",
        }

        refreshes = "native_refresh_tokens"
        assert any(
            key["referred_table"] == "native_auth_sessions"
            and key["constrained_columns"] == ["session_id"]
            for key in inspector.get_foreign_keys(refreshes)
        )
        refresh_checks = {
            constraint["name"] for constraint in inspector.get_check_constraints(refreshes)
        }
        assert {
            "ck_native_refresh_token_hash_length",
            "ck_native_refresh_replacement_hash_length",
            "ck_native_refresh_consumption_state",
        }.issubset(refresh_checks)
        refresh_indexes = {item["name"]: item for item in inspector.get_indexes(refreshes)}
        assert refresh_indexes["uq_native_refresh_tokens_one_active_per_session"]["unique"]
        assert "consumed_at IS NULL" in refresh_indexes[
            "uq_native_refresh_tokens_one_active_per_session"
        ]["dialect_options"]["postgresql_where"]
        assert {
            "ix_native_refresh_tokens_session_id",
            "ix_native_refresh_tokens_expires_at",
        }.issubset(refresh_indexes)

        product_checks = {
            constraint["name"] for constraint in inspector.get_check_constraints("products")
        }
        assert "ck_products_image_media_type" in product_checks
    finally:
        engine.dispose()
