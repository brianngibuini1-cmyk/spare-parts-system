"""Tests for application startup, health checks, and auth primitives."""

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.security import hash_password, verify_password


def make_test_app(database_url="sqlite:///:memory:"):
    return create_app(Settings(database_url=database_url))


def test_unauthenticated_dashboard_redirects_to_login(test_database_url):
    with TestClient(make_test_app(test_database_url)) as client:
        response = client.get("/", follow_redirects=False)

    assert response.status_code == 303
    assert response.headers["location"] == "/login"


def test_demo_page_is_served_separately_from_the_foundation_shell(test_database_url):
    with TestClient(make_test_app(test_database_url)) as client:
        response = client.get("/demo")

    assert response.status_code == 200
    assert "Fictional demonstration data" in response.text
    assert "Supplier details" in response.text
    assert "Stock receiving" in response.text


def test_liveness_does_not_require_database():
    with TestClient(create_app(Settings(database_url="postgresql+psycopg://invalid/db"))) as client:
        response = client.get("/health/live")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readiness_verifies_database_connection(test_database_url):
    with TestClient(make_test_app(test_database_url)) as client:
        response = client.get("/health/ready")
        readiness_route = next(
            route for route in client.app.routes if getattr(route, "path", None) == "/health/ready"
        )

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "database": "ok"}
    assert readiness_route.response_model is None


def test_readiness_returns_sanitized_unavailable_response():
    with TestClient(create_app(Settings(database_url="postgresql+psycopg://invalid/db"))) as client:
        response = client.get("/health/ready")

    assert response.status_code == 503
    assert response.json() == {"status": "unavailable", "database": "unavailable"}
    assert "invalid" not in response.text


def test_password_hash_is_not_plaintext_and_verifies():
    password = "foundation-test-password"
    encoded = hash_password(password)

    assert encoded != password
    assert verify_password(password, encoded)
    assert not verify_password("wrong-password", encoded)


def test_production_configuration_requires_explicit_postgres_url(monkeypatch):
    monkeypatch.delenv("SPARE_PARTS_DATABASE_URL", raising=False)
    with pytest.raises(ValueError, match="SPARE_PARTS_DATABASE_URL"):
        Settings(_env_file=None, environment="production")


def test_production_configuration_keeps_https_and_secure_cookies_enforced():
    r2_kwargs = {
        "product_image_storage_backend": "r2",
        "r2_endpoint_url": "https://account-id.r2.cloudflarestorage.com",
        "r2_bucket": "bmm-private-images",
        "r2_access_key_id": "dummy-access-key",
        "r2_secret_access_key": "dummy-secret-key",
    }
    settings = Settings(
        _env_file=None,
        environment="production",
        database_url="postgresql+psycopg://user:pass@localhost/shop",
        **r2_kwargs,
    )
    assert settings.cookie_secure is True
    assert settings.native_https_required is True
    with pytest.raises(ValueError, match="secure cookies"):
        Settings(
            _env_file=None,
            environment="production",
            database_url="postgresql+psycopg://user:pass@localhost/shop",
            cookie_secure=False,
            **r2_kwargs,
        )


def test_production_configuration_requires_installed_postgresql_driver():
    with pytest.raises(ValueError, match="installed psycopg driver"):
        Settings(
            _env_file=None,
            environment="production",
            database_url="postgresql://user:pass@localhost/shop",
        )
