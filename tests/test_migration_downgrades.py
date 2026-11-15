"""PostgreSQL-only checks for guarded authentication migration downgrades."""

from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect, text

from app.config import get_settings

ROOT = Path(__file__).resolve().parents[1]


def _config(database_url: str, monkeypatch) -> Config:
    monkeypatch.setenv("SPARE_PARTS_DATABASE_URL", database_url)
    get_settings.cache_clear()
    config = Config(str(ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(ROOT / "migrations"))
    return config


def _upgrade(database_url: str, revision: str, monkeypatch) -> Config:
    config = _config(database_url, monkeypatch)
    command.upgrade(config, revision)
    return config


def _downgrade(database_url: str, revision: str, monkeypatch) -> None:
    command.downgrade(_config(database_url, monkeypatch), revision)


def _revision(engine) -> str:
    with engine.connect() as connection:
        return connection.execute(text("SELECT version_num FROM alembic_version")).scalar_one()


def _insert_legacy_owner(connection) -> None:
    connection.execute(
        text(
            "INSERT INTO owner_accounts "
            "(id, login_name, password_hash, is_active, created_at) "
            "VALUES (1, 'owner@example.test', 'preserved-test-hash', TRUE, CURRENT_TIMESTAMP)"
        )
    )
    connection.execute(
        text(
            "INSERT INTO auth_sessions "
            "(owner_id, token_hash, csrf_token_hash, created_at, last_seen_at, "
            "idle_expires_at, absolute_expires_at) "
            "VALUES (1, :token_hash, :csrf_hash, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, "
            "CURRENT_TIMESTAMP + INTERVAL '20 minutes', "
            "CURRENT_TIMESTAMP + INTERVAL '12 hours')"
        ),
        {"token_hash": "a" * 64, "csrf_hash": "b" * 64},
    )
    connection.execute(
        text(
            "INSERT INTO auth_events (owner_id, event_type, occurred_at) "
            "VALUES (1, 'owner_provisioned', CURRENT_TIMESTAMP)"
        )
    )


def _insert_auth_event(engine, event_type: str) -> None:
    with engine.begin() as connection:
        connection.execute(
            text(
                "INSERT INTO auth_events (event_type, occurred_at) "
                "VALUES (:event_type, CURRENT_TIMESTAMP)"
            ),
            {"event_type": event_type},
        )


def test_0004_downgrade_preserves_owner_sessions_and_audit(
    migration_downgrade_database_url, monkeypatch
):
    engine = create_engine(migration_downgrade_database_url)
    try:
        _upgrade(migration_downgrade_database_url, "0003_client_login_throttling", monkeypatch)
        with engine.begin() as connection:
            _insert_legacy_owner(connection)
        _upgrade(migration_downgrade_database_url, "0004_named_user_roles", monkeypatch)

        _downgrade(
            migration_downgrade_database_url, "0003_client_login_throttling", monkeypatch
        )

        assert _revision(engine) == "0003_client_login_throttling"
        assert "user_id" not in {
            column["name"] for column in inspect(engine).get_columns("auth_sessions")
        }
        with engine.connect() as connection:
            assert connection.execute(
                text("SELECT password_hash FROM owner_accounts WHERE id = 1")
            ).scalar_one() == "preserved-test-hash"
            assert connection.execute(text("SELECT COUNT(*) FROM auth_sessions")).scalar_one() == 1
            assert connection.execute(
                text("SELECT COUNT(*) FROM auth_events WHERE event_type='owner_provisioned'")
            ).scalar_one() == 1
    finally:
        engine.dispose()
        get_settings.cache_clear()


def test_0004_downgrade_refuses_attendant_sessions_without_changing_schema_or_records(
    migration_downgrade_database_url, monkeypatch
):
    engine = create_engine(migration_downgrade_database_url)
    try:
        _upgrade(migration_downgrade_database_url, "0003_client_login_throttling", monkeypatch)
        with engine.begin() as connection:
            _insert_legacy_owner(connection)
        _upgrade(migration_downgrade_database_url, "0004_named_user_roles", monkeypatch)
        with engine.begin() as connection:
            connection.execute(
                text(
                    "INSERT INTO users (id, login_name, password_hash, role, is_active, created_at) "
                    "VALUES (2, 'attendant@example.test', 'attendant-test-hash', 'attendant', "
                    "TRUE, CURRENT_TIMESTAMP)"
                )
            )
            connection.execute(
                text(
                    "INSERT INTO auth_sessions "
                    "(owner_id, user_id, token_hash, csrf_token_hash, created_at, last_seen_at, "
                    "idle_expires_at, absolute_expires_at) "
                    "VALUES (NULL, 2, :token_hash, :csrf_hash, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, "
                    "CURRENT_TIMESTAMP + INTERVAL '20 minutes', "
                    "CURRENT_TIMESTAMP + INTERVAL '12 hours')"
                ),
                {"token_hash": "c" * 64, "csrf_hash": "d" * 64},
            )
            connection.execute(
                text(
                    "INSERT INTO auth_events (actor_id, event_type, occurred_at) "
                    "VALUES (2, 'login_succeeded', CURRENT_TIMESTAMP)"
                )
            )

        with pytest.raises(RuntimeError, match="attendant account IDs.*no schema changes"):
            command.downgrade(
                _config(migration_downgrade_database_url, monkeypatch),
                "0003_client_login_throttling",
            )

        assert _revision(engine) == "0004_named_user_roles"
        assert "user_id" in {
            column["name"] for column in inspect(engine).get_columns("auth_sessions")
        }
        with engine.connect() as connection:
            assert connection.execute(
                text("SELECT COUNT(*) FROM users WHERE role='attendant'")
            ).scalar_one() == 1
            assert connection.execute(
                text("SELECT COUNT(*) FROM auth_sessions WHERE token_hash=:token_hash"),
                {"token_hash": "c" * 64},
            ).scalar_one() == 1
            assert connection.execute(
                text("SELECT COUNT(*) FROM auth_events WHERE actor_id=2")
            ).scalar_one() == 1
    finally:
        engine.dispose()
        get_settings.cache_clear()


def test_0006_downgrade_without_attendant_events_preserves_other_audit_records(
    migration_downgrade_database_url, monkeypatch
):
    engine = create_engine(migration_downgrade_database_url)
    try:
        _upgrade(migration_downgrade_database_url, "0006_attendant_auth_events", monkeypatch)
        _insert_auth_event(engine, "login_limited")
        _downgrade(migration_downgrade_database_url, "0005_product_catalogue", monkeypatch)

        assert _revision(engine) == "0005_product_catalogue"
        with engine.connect() as connection:
            assert connection.execute(
                text("SELECT COUNT(*) FROM auth_events WHERE event_type='login_limited'")
            ).scalar_one() == 1
    finally:
        engine.dispose()
        get_settings.cache_clear()


def test_0006_downgrade_refuses_attendant_events_and_preserves_audit(
    migration_downgrade_database_url, monkeypatch
):
    engine = create_engine(migration_downgrade_database_url)
    try:
        _upgrade(migration_downgrade_database_url, "0006_attendant_auth_events", monkeypatch)
        _insert_auth_event(engine, "attendant_created")

        with pytest.raises(
            RuntimeError, match="attendant audit events.*all audit records are preserved"
        ):
            _downgrade(
                migration_downgrade_database_url, "0005_product_catalogue", monkeypatch
            )

        assert _revision(engine) == "0006_attendant_auth_events"
        with engine.connect() as connection:
            assert connection.execute(
                text("SELECT COUNT(*) FROM auth_events WHERE event_type='attendant_created'")
            ).scalar_one() == 1
    finally:
        engine.dispose()
        get_settings.cache_clear()


def test_0007_downgrade_without_native_records_preserves_existing_audit(
    migration_downgrade_database_url, monkeypatch
):
    engine = create_engine(migration_downgrade_database_url)
    try:
        _upgrade(migration_downgrade_database_url, "head", monkeypatch)
        _insert_auth_event(engine, "attendant_status_changed")
        _downgrade(
            migration_downgrade_database_url, "0006_attendant_auth_events", monkeypatch
        )

        assert _revision(engine) == "0006_attendant_auth_events"
        assert not inspect(engine).has_table("native_auth_sessions")
        assert not inspect(engine).has_table("native_refresh_tokens")
        with engine.connect() as connection:
            assert connection.execute(
                text("SELECT COUNT(*) FROM auth_events WHERE event_type='attendant_status_changed'")
            ).scalar_one() == 1
    finally:
        engine.dispose()
        get_settings.cache_clear()


def test_0007_downgrade_refuses_native_events_and_preserves_audit(
    migration_downgrade_database_url, monkeypatch
):
    engine = create_engine(migration_downgrade_database_url)
    try:
        _upgrade(migration_downgrade_database_url, "head", monkeypatch)
        _insert_auth_event(engine, "native_login_succeeded")

        with pytest.raises(
            RuntimeError, match="native authentication events.*all records are preserved"
        ):
            _downgrade(
                migration_downgrade_database_url, "0006_attendant_auth_events", monkeypatch
            )

        assert _revision(engine) == "0007_native_auth_sessions"
        assert inspect(engine).has_table("native_auth_sessions")
        with engine.connect() as connection:
            assert connection.execute(
                text("SELECT COUNT(*) FROM auth_events WHERE event_type='native_login_succeeded'")
            ).scalar_one() == 1
    finally:
        engine.dispose()
        get_settings.cache_clear()


def test_0007_downgrade_refuses_native_sessions_and_refresh_history(
    migration_downgrade_database_url, monkeypatch
):
    engine = create_engine(migration_downgrade_database_url)
    try:
        _upgrade(migration_downgrade_database_url, "0003_client_login_throttling", monkeypatch)
        with engine.begin() as connection:
            _insert_legacy_owner(connection)
        _upgrade(migration_downgrade_database_url, "head", monkeypatch)
        with engine.begin() as connection:
            native_session_id = connection.execute(
                text(
                    "INSERT INTO native_auth_sessions "
                    "(user_id, access_token_hash, created_at, last_refresh_at, idle_expires_at, "
                    "absolute_expires_at, access_expires_at) VALUES "
                    "(1, :access_hash, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, "
                    "CURRENT_TIMESTAMP + INTERVAL '20 minutes', "
                    "CURRENT_TIMESTAMP + INTERVAL '12 hours', "
                    "CURRENT_TIMESTAMP + INTERVAL '10 minutes') RETURNING id"
                ),
                {"access_hash": "e" * 64},
            ).scalar_one()
            connection.execute(
                text(
                    "INSERT INTO native_refresh_tokens "
                    "(token_hash, session_id, issued_at, expires_at) VALUES "
                    "(:token_hash, :session_id, CURRENT_TIMESTAMP, "
                    "CURRENT_TIMESTAMP + INTERVAL '12 hours')"
                ),
                {"token_hash": "f" * 64, "session_id": native_session_id},
            )

        with pytest.raises(
            RuntimeError, match="native session/refresh rows.*all records are preserved"
        ):
            _downgrade(
                migration_downgrade_database_url, "0006_attendant_auth_events", monkeypatch
            )

        assert _revision(engine) == "0007_native_auth_sessions"
        with engine.connect() as connection:
            assert connection.execute(
                text("SELECT COUNT(*) FROM native_auth_sessions")
            ).scalar_one() == 1
            assert connection.execute(
                text("SELECT COUNT(*) FROM native_refresh_tokens WHERE token_hash=:token_hash"),
                {"token_hash": "f" * 64},
            ).scalar_one() == 1
    finally:
        engine.dispose()
        get_settings.cache_clear()
