from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import sessionmaker

from app import auth_cli
from app.auth import provision_owner, prune_auth_data
from app.config import Settings
from app.database import Base, create_database_engine
from app.main import create_app
from app.models import AuthEvent, AuthSession, LoginThrottle, OwnerAccount, UserAccount

PASSWORD = "a-long-enough-test-password"


@pytest.fixture
def client(tmp_path, test_database_url):
    database_url = test_database_url
    settings = Settings(
        database_url=database_url,
        cookie_secure=True,
        login_failure_limit=2,
        product_image_storage_path=str(tmp_path / "private-images"),
        product_image_max_bytes=1024,
    )
    app = create_app(settings)
    Base.metadata.create_all(app.state.engine)
    with app.state.session_factory() as session:
        provision_owner(session, "owner@example.test", PASSWORD)
        session.commit()
    with TestClient(
        app, base_url="https://testserver", client=("192.0.2.10", 12345)
    ) as test_client:
        yield test_client


def _login(client, password=PASSWORD):
    return client.post(
        "/api/v1/auth/login",
        headers={"Origin": "https://testserver"},
        json={"login_name": "owner@example.test", "password": password},
    )


def test_successful_login_issues_secure_server_session_and_protects_dashboard(client):
    response = _login(client)

    assert response.status_code == 200
    assert response.json() == {"login_name": "owner@example.test"}
    session_cookie = response.cookies.get("spare_parts_session")
    csrf_cookie = response.cookies.get("spare_parts_csrf")
    assert session_cookie
    assert csrf_cookie
    set_cookie = response.headers.get_list("set-cookie")
    assert any("spare_parts_session=" in item and "HttpOnly" in item and "Secure" in item for item in set_cookie)
    assert any("spare_parts_csrf=" in item and "SameSite=strict" in item for item in set_cookie)
    assert client.get("/api/v1/auth/me").json() == {
        "login_name": "owner@example.test", "role": "owner"
    }
    assert client.get("/").status_code == 200


def test_invalid_credentials_are_generic_and_do_not_authenticate(client):
    response = _login(client, "wrong-password-value")

    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid login name or password."}
    assert "spare_parts_session" not in response.cookies
    assert client.get("/api/v1/auth/me").status_code == 401


def test_logout_revokes_session_and_clears_cookies(client):
    assert _login(client).status_code == 200
    csrf = client.cookies.get("spare_parts_csrf")

    response = client.post("/api/v1/auth/logout", headers={"X-CSRF-Token": csrf})

    assert response.status_code == 204
    assert client.get("/api/v1/auth/me").status_code == 401
    with client.app.state.session_factory() as session:
        stored_session = session.query(AuthSession).one()
        assert stored_session.revoked_at is not None


def test_invalid_csrf_token_rejects_logout_without_revoking_session(client):
    assert _login(client).status_code == 200

    response = client.post("/api/v1/auth/logout", headers={"X-CSRF-Token": "incorrect"})

    assert response.status_code == 403
    assert client.get("/api/v1/auth/me").status_code == 200
    with client.app.state.session_factory() as session:
        assert session.query(AuthSession).one().revoked_at is None


def test_expired_idle_session_is_rejected(client):
    assert _login(client).status_code == 200
    with client.app.state.session_factory() as session:
        stored_session = session.query(AuthSession).one()
        stored_session.idle_expires_at = datetime.now(UTC) - timedelta(seconds=1)
        session.commit()

    assert client.get("/api/v1/auth/me").status_code == 401


def test_expired_absolute_session_is_rejected(client):
    assert _login(client).status_code == 200
    with client.app.state.session_factory() as session:
        stored_session = session.query(AuthSession).one()
        expired = datetime.now(UTC) - timedelta(seconds=2)
        stored_session.idle_expires_at = expired - timedelta(seconds=1)
        stored_session.absolute_expires_at = expired
        session.commit()

    assert client.get("/api/v1/auth/me").status_code == 401


def test_protected_functionality_rejects_unauthenticated_requests(client):
    protected_routes = (
        ("GET", "/api/v1/auth/me"),
        ("POST", "/api/v1/auth/logout"),
        ("GET", "/"),
    )
    for method, path in protected_routes:
        response = client.request(method, path, follow_redirects=False)
        assert response.status_code in (303, 401)
    assert client.get("/", follow_redirects=False).headers["location"] == "/login"


def test_login_throttle_is_per_client_and_ignores_forwarded_headers(client):
    assert _login(client, "wrong-password-value").status_code == 401
    assert _login(client, "wrong-password-value").status_code == 401
    limited = client.post(
        "/api/v1/auth/login",
        headers={"Origin": "https://testserver", "X-Forwarded-For": "198.51.100.99"},
        json={"login_name": "owner@example.test", "password": PASSWORD},
    )
    assert limited.status_code == 429
    with client.app.state.session_factory() as session:
        assert session.query(LoginThrottle).count() == 1
        assert session.query(AuthEvent).filter_by(event_type="login_limited").count() == 1


def test_bad_attempts_from_another_client_cannot_lock_owner_account(client):
    assert _login(client, "wrong-password-value").status_code == 401
    assert _login(client, "wrong-password-value").status_code == 401
    assert _login(client).status_code == 429

    with TestClient(
        client.app, base_url="https://testserver", client=("198.51.100.20", 23456)
    ) as other_client:
        response = _login(other_client)

    assert response.status_code == 200


def test_session_activity_writes_are_throttled(client):
    assert _login(client).status_code == 200
    with client.app.state.session_factory() as session:
        stored = session.query(AuthSession).one()
        last_seen = stored.last_seen_at
        idle_expiry = stored.idle_expires_at

    assert client.get("/api/v1/auth/me").status_code == 200
    with client.app.state.session_factory() as session:
        stored = session.query(AuthSession).one()
        assert stored.last_seen_at == last_seen
        assert stored.idle_expires_at == idle_expiry


def test_security_headers_are_present_and_csp_allows_current_frontend(client):
    response = client.get("/login")
    assert response.status_code == 200
    assert "script-src 'self'" in response.headers["content-security-policy"]
    assert "style-src 'self' 'unsafe-inline'" in response.headers["content-security-policy"]
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["referrer-policy"] == "strict-origin-when-cross-origin"
    assert response.headers["x-frame-options"] == "DENY"


def test_authentication_retention_prunes_old_throttles_events_and_sessions(client):
    settings = client.app.state.settings.model_copy(
        update={"login_throttle_retention_seconds": 60, "auth_event_retention_days": 1}
    )
    now = datetime.now(UTC)
    with client.app.state.session_factory() as session:
        session.add(
            LoginThrottle(
                client_digest="a" * 64,
                window_started_at=now - timedelta(minutes=2),
                failed_attempts=1,
            )
        )
        session.add(
            AuthEvent(legacy_owner_id=1, actor_id=1, event_type="login_limited", occurred_at=now - timedelta(days=2))
        )
        expired_at = now - timedelta(seconds=1)
        session.add(
            AuthSession(
                legacy_owner_id=1,
                user_id=1,
                token_hash="b" * 64,
                csrf_token_hash="c" * 64,
                created_at=now - timedelta(hours=1),
                last_seen_at=now - timedelta(hours=1),
                idle_expires_at=expired_at,
                absolute_expires_at=now + timedelta(hours=1),
            )
        )
        session.commit()
        counts = prune_auth_data(session, settings, now)
        session.commit()

    assert counts["throttles"] == 1
    assert counts["events"] == 1
    assert counts["sessions"] == 1


def test_owner_singleton_and_login_name_constraints(client):
    with client.app.state.session_factory() as session:
        session.add(OwnerAccount(id=2, login_name="other", password_hash="hash"))
        with pytest.raises(IntegrityError):
            session.commit()


def test_owner_provisioning_creates_unified_owner_role(client):
    with client.app.state.session_factory() as session:
        user = session.query(UserAccount).one()
        assert user.role == "owner"
        assert user.login_name == "owner@example.test"
        session.rollback()
        session.add(OwnerAccount(id=1, login_name="owner@example.test", password_hash="hash"))
        with pytest.raises(IntegrityError):
            session.commit()


def test_provisioning_database_errors_do_not_leak_sql_values(
    monkeypatch, test_database_url, capsys, caplog
):
    engine = create_database_engine(test_database_url)
    Base.metadata.create_all(engine)
    settings = Settings(database_url=test_database_url)
    monkeypatch.setattr(auth_cli, "get_settings", lambda: settings)
    monkeypatch.setattr(auth_cli, "create_database_engine", lambda _: engine)
    monkeypatch.setattr(auth_cli, "create_session_factory", lambda _: sessionmaker(bind=engine))
    monkeypatch.setattr("builtins.input", lambda _: "owner@example.test")
    monkeypatch.setattr(auth_cli.getpass, "getpass", lambda _: "top-secret-password-value")
    secret_hash = "$argon2id$confidential-password-hash"

    def fail_provision(*_args, **_kwargs):
        raise IntegrityError(
            "INSERT INTO owner_accounts", {"password": "top-secret-password-value", "password_hash": secret_hash},
            Exception("constraint failure"),
        )

    monkeypatch.setattr(auth_cli, "provision_owner", fail_provision)
    monkeypatch.setattr("sys.argv", ["auth_cli"])

    assert auth_cli.main() == 2
    output = capsys.readouterr()
    combined = output.out + output.err + caplog.text
    assert "top-secret-password-value" not in combined
    assert secret_hash not in combined
    engine.dispose()


def test_cli_does_not_echo_unrecognized_arguments(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["auth_cli", "top-secret-password-value"])

    assert auth_cli.main() == 2
    output = capsys.readouterr()
    assert "top-secret-password-value" not in output.out + output.err
