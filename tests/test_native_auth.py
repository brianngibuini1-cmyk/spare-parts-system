from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
import os
from pathlib import Path
from threading import Barrier

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, inspect, select, text
from sqlalchemy.engine import make_url

import app.native_auth as native_auth_module
from app.auth import provision_attendant, provision_owner
from app.config import Settings, get_settings
from app.database import Base
from app.main import create_app
from app.models import AuthEvent, NativeAuthSession, NativeRefreshToken

OWNER_PASSWORD = "native-owner-test-password-15"
ATTENDANT_PASSWORD = "native-attendant-test-password"


@pytest.fixture
def native_client(tmp_path, test_database_url):
    app = create_app(
        Settings(
            database_url=test_database_url,
            cookie_secure=True,
            native_access_token_seconds=600,
            native_session_idle_seconds=1800,
            native_session_absolute_seconds=43200,
            product_image_storage_path=str(tmp_path / "private-images"),
        )
    )
    Base.metadata.create_all(app.state.engine)
    with app.state.session_factory() as session:
        provision_owner(session, "owner@example.test", OWNER_PASSWORD)
        session.flush()
        provision_attendant(session, "attendant@example.test", ATTENDANT_PASSWORD)
        session.commit()
    client = TestClient(app, base_url="https://testserver", client=("192.0.2.31", 41000))
    yield client
    client.close()
    app.state.engine.dispose()


def _login(client: TestClient, login_name="owner@example.test", password=OWNER_PASSWORD):
    return client.post(
        "/api/v1/native/auth/login",
        json={"login_name": login_name, "password": password},
    )


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_owner_and_attendant_login_use_database_roles(native_client):
    owner = _login(native_client)
    attendant = _login(native_client, "attendant@example.test", ATTENDANT_PASSWORD)

    assert owner.status_code == 200
    assert owner.json()["user"]["role"] == "OWNER"
    assert attendant.status_code == 200
    assert attendant.json()["user"]["role"] == "SHOP_ATTENDANT"
    assert native_client.get(
        "/api/v1/native/auth/me", headers=_bearer(attendant.json()["access_token"])
    ).json()["role"] == "SHOP_ATTENDANT"
    client_role = native_client.post(
        "/api/v1/native/auth/login",
        json={
            "login_name": "attendant@example.test",
            "password": ATTENDANT_PASSWORD,
            "role": "OWNER",
        },
    )
    assert client_role.status_code == 422
    assert "OWNER" not in client_role.text


def test_invalid_credentials_are_generic(native_client):
    response = _login(native_client, password="incorrect-password-value")

    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid login name or password."}
    assert "access_token" not in response.text


def test_native_validation_errors_do_not_echo_passwords_or_refresh_tokens(native_client):
    secret_password = "validation-secret-" + ("x" * 1024)
    invalid_login = native_client.post(
        "/api/v1/native/auth/login",
        json={"login_name": "owner@example.test", "password": secret_password},
    )
    secret_refresh = "refresh-secret"
    invalid_refresh = native_client.post(
        "/api/v1/native/auth/refresh", json={"refresh_token": secret_refresh}
    )

    assert invalid_login.status_code == 422
    assert invalid_refresh.status_code == 422
    assert secret_password not in invalid_login.text
    assert secret_refresh not in invalid_refresh.text


def test_native_credentials_require_https_by_default(native_client):
    issued = _login(native_client).json()
    insecure_client = TestClient(
        native_client.app, base_url="http://testserver", client=("192.0.2.35", 43000)
    )

    assert insecure_client.post(
        "/api/v1/native/auth/login",
        json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
    ).status_code == 403
    assert insecure_client.get(
        "/api/v1/native/auth/me", headers=_bearer(issued["access_token"])
    ).status_code == 403


@pytest.mark.parametrize("authorization", [None, "Bearer", "Basic abc", "Bearer ", "Bearer x"])
def test_missing_and_malformed_or_invalid_access_tokens_are_rejected(native_client, authorization):
    headers = {} if authorization is None else {"Authorization": authorization}
    response = native_client.get("/api/v1/native/auth/me", headers=headers)

    assert response.status_code == 401
    assert response.headers.get("www-authenticate") == "Bearer"


def test_bearer_token_authorizes_operations_but_database_role_controls_permissions(native_client):
    owner = _login(native_client).json()
    attendant = _login(native_client, "attendant@example.test", ATTENDANT_PASSWORD).json()

    created = native_client.post(
        "/api/v1/products",
        headers=_bearer(attendant["access_token"]),
        json={"name": "Test water pump"},
    )
    assert created.status_code == 201
    assert native_client.get(
        "/api/v1/products/pending", headers=_bearer(attendant["access_token"])
    ).status_code == 403
    assert native_client.get(
        "/api/v1/products/pending", headers=_bearer(owner["access_token"])
    ).status_code == 200
    provisioned = native_client.post(
        "/api/v1/attendants",
        headers=_bearer(owner["access_token"]),
        json={"login_name": "new-attendant@example.test", "password": ATTENDANT_PASSWORD},
    )
    assert provisioned.status_code == 201
    assert provisioned.json()["role"] == "SHOP_ATTENDANT"
    with native_client.app.state.session_factory() as session:
        assert session.query(AuthEvent).filter_by(event_type="attendant_created").count() == 1
    assert native_client.post(
        "/api/v1/attendants",
        headers=_bearer(attendant["access_token"]),
        json={"login_name": "self-appointed@example.test", "password": "long-enough-password"},
    ).status_code == 403
    invalid_role = native_client.post(
        "/api/v1/attendants",
        headers=_bearer(owner["access_token"]),
        json={
            "login_name": "role-change@example.test",
            "password": "validation-secret-password",
            "role": "owner",
        },
    )
    assert invalid_role.status_code == 422
    assert "validation-secret-password" not in invalid_role.text


def test_access_token_expiry_is_enforced(native_client):
    response = _login(native_client)
    token = response.json()["access_token"]
    with native_client.app.state.session_factory() as session:
        native_session = session.scalar(select(NativeAuthSession))
        native_session.access_expires_at = datetime.now(UTC) - timedelta(seconds=1)
        session.commit()

    assert native_client.get("/api/v1/native/auth/me", headers=_bearer(token)).status_code == 401


@pytest.mark.parametrize("expiry_field", ["idle_expires_at", "absolute_expires_at"])
def test_refresh_session_idle_and_absolute_expiry_are_enforced(native_client, expiry_field):
    issued = _login(native_client).json()
    with native_client.app.state.session_factory() as session:
        native_session = session.scalar(select(NativeAuthSession))
        setattr(native_session, expiry_field, datetime.now(UTC) - timedelta(seconds=1))
        if expiry_field == "absolute_expires_at":
            native_session.idle_expires_at = native_session.absolute_expires_at
            native_session.access_expires_at = native_session.absolute_expires_at
        session.commit()

    response = native_client.post(
        "/api/v1/native/auth/refresh", json={"refresh_token": issued["refresh_token"]}
    )

    assert response.status_code == 401


def test_refresh_rotates_tokens_and_only_hashes_are_stored(native_client):
    issued = _login(native_client).json()
    with native_client.app.state.session_factory() as session:
        stored_session = session.scalar(select(NativeAuthSession))
        stored_refresh = session.scalar(select(NativeRefreshToken))
        assert stored_session.access_token_hash != issued["access_token"]
        assert stored_refresh.token_hash != issued["refresh_token"]

    rotated = native_client.post(
        "/api/v1/native/auth/refresh", json={"refresh_token": issued["refresh_token"]}
    )

    assert rotated.status_code == 200
    assert rotated.json()["access_token"] != issued["access_token"]
    assert rotated.json()["refresh_token"] != issued["refresh_token"]
    assert native_client.get(
        "/api/v1/native/auth/me", headers=_bearer(issued["access_token"])
    ).status_code == 401
    assert native_client.get(
        "/api/v1/native/auth/me", headers=_bearer(rotated.json()["access_token"])
    ).status_code == 200


def test_refresh_token_reuse_revokes_the_family_and_is_audited(native_client):
    issued = _login(native_client).json()
    rotated = native_client.post(
        "/api/v1/native/auth/refresh", json={"refresh_token": issued["refresh_token"]}
    ).json()

    replay = native_client.post(
        "/api/v1/native/auth/refresh", json={"refresh_token": issued["refresh_token"]}
    )

    assert replay.status_code == 401
    assert native_client.get(
        "/api/v1/native/auth/me", headers=_bearer(rotated["access_token"])
    ).status_code == 401
    with native_client.app.state.session_factory() as session:
        assert session.scalar(select(NativeAuthSession)).revoked_at is not None
        assert session.query(AuthEvent).filter_by(event_type="native_refresh_reuse_detected").count() == 1


def test_logout_revokes_access_and_refresh_credentials(native_client):
    issued = _login(native_client).json()
    response = native_client.post(
        "/api/v1/native/auth/logout", json={"refresh_token": issued["refresh_token"]}
    )

    assert response.status_code == 204
    assert response.content == b""
    assert native_client.get(
        "/api/v1/native/auth/me", headers=_bearer(issued["access_token"])
    ).status_code == 401
    assert native_client.post(
        "/api/v1/native/auth/refresh", json={"refresh_token": issued["refresh_token"]}
    ).status_code == 401


def test_concurrent_refresh_cannot_create_two_active_token_families(native_client, monkeypatch):
    if os.getenv("SPARE_PARTS_TEST_DATABASE_URL"):
        assert native_client.app.state.engine.dialect.name == "postgresql"
        # Exercise PostgreSQL's row lock and partial unique index directly;
        # do not let the local development lock serialize the two requests.
        monkeypatch.setattr(
            native_auth_module,
            "_refresh_lock",
            lambda _token_hash: native_auth_module._RefreshLock(),
        )
    issued = _login(native_client).json()
    barrier = Barrier(2)

    def refresh_once(_index):
        concurrent_client = TestClient(
            native_client.app,
            base_url="https://testserver",
            client=("192.0.2.32", 42000),
        )
        barrier.wait(timeout=5)
        return concurrent_client.post(
            "/api/v1/native/auth/refresh",
            json={"refresh_token": issued["refresh_token"]},
        )

    with ThreadPoolExecutor(max_workers=2) as executor:
        responses = list(executor.map(refresh_once, range(2)))

    assert sorted(response.status_code for response in responses) == [200, 401]
    assert sum(response.status_code == 200 for response in responses) == 1
    with native_client.app.state.session_factory() as session:
        active_refresh_tokens = session.query(NativeRefreshToken).filter_by(consumed_at=None).count()
        assert active_refresh_tokens <= 1
        assert session.scalar(select(NativeAuthSession)).revoked_at is not None


def test_existing_owner_and_browser_session_survive_native_migration(tmp_path, monkeypatch):
    from alembic import command
    from alembic.config import Config

    database_url = os.getenv("SPARE_PARTS_MIGRATION_TEST_DATABASE_URL")
    if not database_url and os.getenv("SPARE_PARTS_REQUIRE_POSTGRES_TESTS") == "true":
        pytest.fail("PostgreSQL migration preservation test URL is required by CI.")
    if database_url:
        migration_url = make_url(database_url)
        if (
            migration_url.get_backend_name() != "postgresql"
            or not migration_url.database
            or migration_url.database != "spare_parts_migration_test"
            or migration_url.host not in {"localhost", "127.0.0.1", "::1"}
        ):
            pytest.fail(
                "Migration test URL must target local PostgreSQL database "
                "'spare_parts_migration_test'."
            )
    else:
        database_path = tmp_path / "native-migration-test.db"
        database_url = f"sqlite:///{database_path.as_posix()}"
    monkeypatch.setenv("SPARE_PARTS_DATABASE_URL", database_url)
    get_settings.cache_clear()
    root = Path(__file__).resolve().parents[1]
    alembic_config = Config(str(root / "alembic.ini"))
    alembic_config.set_main_option("script_location", str(root / "migrations"))
    engine = create_engine(database_url)
    if database_url.startswith("postgresql"):
        with engine.begin() as connection:
            connection.exec_driver_sql("DROP SCHEMA public CASCADE")
            connection.exec_driver_sql("CREATE SCHEMA public")
    command.upgrade(alembic_config, "0003_client_login_throttling")
    legacy_hash = "$argon2id$preserved-owner-hash"
    now = datetime.now(UTC).isoformat()
    idle_expiry = (datetime.now(UTC) + timedelta(minutes=20)).isoformat()
    absolute_expiry = (datetime.now(UTC) + timedelta(hours=1)).isoformat()
    with engine.begin() as connection:
        connection.execute(
            text(
                "INSERT INTO owner_accounts (id, login_name, password_hash, is_active, created_at) "
                "VALUES (1, 'owner@example.test', :password_hash, TRUE, :created_at)"
            ),
            {"password_hash": legacy_hash, "created_at": now},
        )
        connection.execute(
            text(
                "INSERT INTO auth_sessions "
                "(owner_id, token_hash, csrf_token_hash, created_at, last_seen_at, "
                "idle_expires_at, absolute_expires_at) "
                "VALUES (1, :token_hash, :csrf_hash, :created_at, :created_at, :idle, :absolute)"
            ),
            {
                "token_hash": "a" * 64,
                "csrf_hash": "b" * 64,
                "created_at": now,
                "idle": idle_expiry,
                "absolute": absolute_expiry,
            },
        )
    command.upgrade(alembic_config, "head")
    try:
        with engine.connect() as connection:
            assert inspect(connection).has_table("native_auth_sessions")
            owner = connection.exec_driver_sql(
                "SELECT role, password_hash FROM users WHERE id=1"
            ).one()
            assert owner.role == "owner"
            assert owner.password_hash == legacy_hash
            migrated_session = connection.exec_driver_sql(
                "SELECT owner_id, user_id, token_hash FROM auth_sessions"
            ).one()
            assert migrated_session.owner_id == 1
            assert migrated_session.user_id == 1
            assert migrated_session.token_hash == "a" * 64
    finally:
        engine.dispose()
        get_settings.cache_clear()
