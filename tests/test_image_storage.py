from __future__ import annotations

import io
import re
from unittest.mock import MagicMock
from uuid import UUID

import pytest
from botocore.exceptions import BotoCoreError, ClientError
from fastapi.testclient import TestClient
from PIL import Image
from pydantic import ValidationError
from sqlalchemy.exc import SQLAlchemyError

from app.auth import provision_owner
from app.config import Settings
from app.database import Base
from app.image_storage import ProductImageStorageError, R2ProductImageStorage
from app.main import create_app
from app.models import Product

_KEY_RE = re.compile(r"^[a-f0-9]{32}\.(?:jpg|png|webp)$")
OWNER_PASSWORD = "owner-test-password-at-least-15"


def _client_error(code: str, status_code: int = 500) -> ClientError:
    return ClientError(
        {
            "Error": {"Code": code, "Message": "mocked error"},
            "ResponseMetadata": {"HTTPStatusCode": status_code},
        },
        "MockOperation",
    )


def _png_bytes() -> bytes:
    image = Image.new("RGB", (8, 8), (30, 90, 150))
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue()


def _make_r2_storage(
    mock_client: MagicMock | None = None,
) -> tuple[R2ProductImageStorage, MagicMock]:
    client = mock_client or MagicMock()
    storage = R2ProductImageStorage(
        endpoint_url="https://account-id.r2.cloudflarestorage.com",
        bucket="bmm-private-images",
        access_key_id="dummy-access-key",
        secret_access_key="dummy-secret-key",
        client=client,
    )
    return storage, client


def test_r2_storage_save_passes_private_bucket_and_random_key():
    storage, client = _make_r2_storage()

    key = storage.save(b"image-bytes", "png")

    assert _KEY_RE.fullmatch(key)
    assert key.endswith(".png")
    client.put_object.assert_called_once()
    kwargs = client.put_object.call_args.kwargs
    assert kwargs["Bucket"] == "bmm-private-images"
    assert kwargs["Key"] == key
    assert kwargs["Body"] == b"image-bytes"
    assert kwargs["ContentType"] == "image/png"
    assert "ACL" not in kwargs


def test_r2_storage_load_returns_bytes_and_closes_stream():
    storage, client = _make_r2_storage()
    body = MagicMock()
    body.read.side_effect = [b"stored-image", b""]
    client.get_object.return_value = {
        "Body": body,
        "ContentType": "image/jpeg",
        "ContentLength": 12,
    }
    key = "a" * 32 + ".jpg"

    loaded = storage.load(key)

    assert loaded == b"stored-image"
    client.get_object.assert_called_once_with(Bucket="bmm-private-images", Key=key)
    assert body.read.call_args_list[0].args == (64 * 1024,)
    assert body.read.call_args_list[1].args == (64 * 1024,)
    body.close.assert_called_once()


def test_r2_storage_load_accumulates_partial_reads_up_to_max_bytes():
    client = MagicMock()
    storage = R2ProductImageStorage(
        endpoint_url="https://account-id.r2.cloudflarestorage.com",
        bucket="bmm-private-images",
        access_key_id="dummy-access-key",
        secret_access_key="dummy-secret-key",
        max_bytes=10,
        client=client,
    )
    body = MagicMock()
    body.read.side_effect = [b"1234", b"567890", b""]
    client.get_object.return_value = {
        "Body": body,
        "ContentType": "image/png",
    }

    loaded = storage.load("a" * 32 + ".png")

    assert loaded == b"1234567890"
    assert [c.args[0] for c in body.read.call_args_list] == [11, 7, 1]
    body.close.assert_called_once()


@pytest.mark.parametrize(
    ("key_ext", "returned_content_type"),
    [
        ("jpg", "image/png"),
        ("png", "image/webp"),
        ("webp", "image/jpeg"),
    ],
)
def test_r2_storage_load_rejects_content_type_mismatch_with_key(key_ext, returned_content_type):
    storage, client = _make_r2_storage()
    body = MagicMock()
    client.get_object.return_value = {
        "Body": body,
        "ContentType": returned_content_type,
    }

    with pytest.raises(ProductImageStorageError, match="does not match"):
        storage.load("a" * 32 + f".{key_ext}")

    body.read.assert_not_called()
    body.close.assert_called_once()


@pytest.mark.parametrize(
    "bad_content_type",
    [None, "", "text/html", "image/svg+xml", "application/octet-stream"],
)
def test_r2_storage_load_rejects_invalid_content_type_and_closes_stream(bad_content_type):
    storage, client = _make_r2_storage()
    body = MagicMock()
    response: dict[str, object] = {"Body": body}
    if bad_content_type is not None:
        response["ContentType"] = bad_content_type
    client.get_object.return_value = response

    with pytest.raises(ProductImageStorageError, match="content type"):
        storage.load("a" * 32 + ".jpg")

    body.read.assert_not_called()
    body.close.assert_called_once()


@pytest.mark.parametrize("bad_length", [-1, "12", True, 5 * 1024 * 1024 + 1])
def test_r2_storage_load_rejects_invalid_or_oversized_content_length_and_closes_stream(bad_length):
    storage, client = _make_r2_storage()
    body = MagicMock()
    client.get_object.return_value = {
        "Body": body,
        "ContentType": "image/png",
        "ContentLength": bad_length,
    }

    with pytest.raises(ProductImageStorageError):
        storage.load("a" * 32 + ".png")

    body.read.assert_not_called()
    body.close.assert_called_once()


def test_r2_storage_load_enforces_max_bytes_on_stream_read_and_closes_stream():
    client = MagicMock()
    storage = R2ProductImageStorage(
        endpoint_url="https://account-id.r2.cloudflarestorage.com",
        bucket="bmm-private-images",
        access_key_id="dummy-access-key",
        secret_access_key="dummy-secret-key",
        max_bytes=16,
        client=client,
    )
    body = MagicMock()
    body.read.side_effect = [b"x" * 10, b"y" * 7]
    client.get_object.return_value = {
        "Body": body,
        "ContentType": "image/webp",
    }

    with pytest.raises(ProductImageStorageError, match="maximum allowed"):
        storage.load("a" * 32 + ".webp")

    assert [c.args[0] for c in body.read.call_args_list] == [17, 7]
    body.close.assert_called_once()


def test_r2_storage_load_close_failure_raises_storage_error_on_success():
    storage, client = _make_r2_storage()
    body = MagicMock()
    body.read.side_effect = [b"ok", b""]
    body.close.side_effect = OSError("close failed")
    client.get_object.return_value = {
        "Body": body,
        "ContentType": "image/jpeg",
    }

    with pytest.raises(ProductImageStorageError, match="close"):
        storage.load("a" * 32 + ".jpg")

    body.close.assert_called_once()


def test_r2_storage_load_close_failure_does_not_mask_primary_error():
    storage, client = _make_r2_storage()
    body = MagicMock()
    body.close.side_effect = RuntimeError("close failed")
    client.get_object.return_value = {
        "Body": body,
        "ContentType": "image/png",
    }

    with pytest.raises(ProductImageStorageError, match="does not match"):
        storage.load("a" * 32 + ".jpg")
    body.close.assert_called_once()

    body2 = MagicMock()
    original_read_exc = OSError("read failed")
    body2.read.side_effect = original_read_exc
    body2.close.side_effect = RuntimeError("close failed")
    client.get_object.return_value = {
        "Body": body2,
        "ContentType": "image/jpeg",
    }

    with pytest.raises(ProductImageStorageError, match="Failed to read") as exc_info:
        storage.load("a" * 32 + ".jpg")
    assert exc_info.value.__cause__ is original_read_exc
    body2.close.assert_called_once()


def test_r2_storage_load_converts_runtime_error_from_read_preserving_cause():
    storage, client = _make_r2_storage()
    body = MagicMock()
    read_error = RuntimeError("unexpected stream error")
    body.read.side_effect = read_error
    client.get_object.return_value = {
        "Body": body,
        "ContentType": "image/jpeg",
    }

    with pytest.raises(ProductImageStorageError, match="Failed to read") as exc_info:
        storage.load("a" * 32 + ".jpg")

    assert exc_info.value.__cause__ is read_error
    body.close.assert_called_once()


def test_r2_storage_load_close_attribute_lookup_failure_raises_storage_error():
    class FailingCloseLookupBody:
        def __init__(self) -> None:
            self._chunks = [b"ok", b""]

        def read(self, _size: int) -> bytes:
            return self._chunks.pop(0)

        @property
        def close(self):
            raise RuntimeError("close attribute lookup failed")

    storage, client = _make_r2_storage()
    client.get_object.return_value = {
        "Body": FailingCloseLookupBody(),
        "ContentType": "image/jpeg",
    }

    with pytest.raises(ProductImageStorageError, match="Failed to close"):
        storage.load("a" * 32 + ".jpg")


def test_r2_storage_load_converts_unexpected_metadata_or_read_failure_and_closes_stream():
    storage, client = _make_r2_storage()
    client.get_object.return_value = "not-a-dict"
    with pytest.raises(ProductImageStorageError):
        storage.load("a" * 32 + ".jpg")

    body = MagicMock()
    body.read.side_effect = OSError("stream reset")
    client.get_object.return_value = {"Body": body, "ContentType": "image/jpeg"}
    with pytest.raises(ProductImageStorageError):
        storage.load("a" * 32 + ".jpg")
    body.close.assert_called_once()


@pytest.mark.parametrize("error", [_client_error("NoSuchKey", 404), _client_error("404", 404)])
def test_r2_storage_load_missing_object_returns_none(error):
    storage, client = _make_r2_storage()
    client.get_object.side_effect = error

    assert storage.load("b" * 32 + ".webp") is None


def test_r2_storage_delete_calls_sdk_and_ignores_missing_object():
    storage, client = _make_r2_storage()
    key = "c" * 32 + ".png"

    storage.delete(key)
    client.delete_object.assert_called_once_with(Bucket="bmm-private-images", Key=key)

    client.delete_object.side_effect = _client_error("NoSuchKey", 404)
    storage.delete(key)


@pytest.mark.parametrize("extension", ["svg", "gif", "exe", "", "../jpg"])
def test_r2_storage_rejects_invalid_extension(extension):
    storage, client = _make_r2_storage()

    with pytest.raises(ValueError, match="Invalid image extension"):
        storage.save(b"bytes", extension)

    client.put_object.assert_not_called()


@pytest.mark.parametrize(
    "bad_key",
    ["../escape.jpg", "folder/" + "a" * 32 + ".jpg", "short.jpg", "A" * 32 + ".jpg"],
)
def test_r2_storage_rejects_invalid_object_key(bad_key):
    storage, client = _make_r2_storage()

    with pytest.raises(ValueError, match="Invalid image storage key"):
        storage.load(bad_key)
    with pytest.raises(ValueError, match="Invalid image storage key"):
        storage.delete(bad_key)

    client.get_object.assert_not_called()
    client.delete_object.assert_not_called()


@pytest.mark.parametrize("exc", [_client_error("AccessDenied", 403), BotoCoreError()])
def test_r2_storage_raises_storage_error_on_sdk_failures(exc):
    storage, client = _make_r2_storage()
    key = "d" * 32 + ".jpg"

    client.put_object.side_effect = exc
    with pytest.raises(ProductImageStorageError):
        storage.save(b"bytes", "jpg")

    client.get_object.side_effect = exc
    with pytest.raises(ProductImageStorageError):
        storage.load(key)

    client.delete_object.side_effect = exc
    with pytest.raises(ProductImageStorageError):
        storage.delete(key)


def test_r2_storage_constructs_boto3_client_with_auto_region_and_timeouts(monkeypatch):
    captured: dict[str, object] = {}

    def fake_boto3_client(service_name, **kwargs):
        captured["service_name"] = service_name
        captured["kwargs"] = kwargs
        return MagicMock()

    monkeypatch.setattr("app.image_storage.boto3.client", fake_boto3_client)

    R2ProductImageStorage(
        endpoint_url="https://account-id.r2.cloudflarestorage.com",
        bucket="bmm-private-images",
        access_key_id="dummy-access-key",
        secret_access_key="dummy-secret-key",
    )

    assert captured["service_name"] == "s3"
    kwargs = captured["kwargs"]
    assert kwargs["endpoint_url"] == "https://account-id.r2.cloudflarestorage.com"
    assert kwargs["region_name"] == "auto"
    assert kwargs["aws_access_key_id"] == "dummy-access-key"
    assert kwargs["aws_secret_access_key"] == "dummy-secret-key"
    config = kwargs["config"]
    assert config.region_name == "auto"
    assert config.signature_version == "s3v4"
    assert config.connect_timeout == 5.0
    assert config.read_timeout == 15.0
    assert config.retries == {"max_attempts": 3, "mode": "standard"}


def test_settings_default_to_local_storage_backend():
    settings = Settings(_env_file=None)
    assert settings.product_image_storage_backend == "local"
    assert settings.product_image_storage_path == "var/product-images"


def test_settings_accept_valid_r2_configuration():
    settings = Settings(
        _env_file=None,
        environment="production",
        database_url="postgresql+psycopg://user:pass@localhost:5432/bmm",
        cookie_secure=True,
        native_https_required=True,
        product_image_storage_backend="r2",
        r2_endpoint_url="https://account-id.r2.cloudflarestorage.com",
        r2_bucket="bmm-private-images",
        r2_access_key_id="dummy-access-key",
        r2_secret_access_key="dummy-secret-key",
    )
    assert settings.product_image_storage_backend == "r2"


@pytest.mark.parametrize(
    "missing_field,expected_env",
    [
        ("r2_endpoint_url", "SPARE_PARTS_R2_ENDPOINT_URL"),
        ("r2_bucket", "SPARE_PARTS_R2_BUCKET"),
        ("r2_access_key_id", "SPARE_PARTS_R2_ACCESS_KEY_ID"),
        ("r2_secret_access_key", "SPARE_PARTS_R2_SECRET_ACCESS_KEY"),
    ],
)
def test_settings_reject_missing_r2_configuration(missing_field, expected_env):
    kwargs = {
        "product_image_storage_backend": "r2",
        "r2_endpoint_url": "https://account-id.r2.cloudflarestorage.com",
        "r2_bucket": "bmm-private-images",
        "r2_access_key_id": "dummy-access-key",
        "r2_secret_access_key": "dummy-secret-key",
    }
    kwargs[missing_field] = ""

    with pytest.raises(ValidationError) as exc_info:
        Settings(_env_file=None, **kwargs)

    message = exc_info.value.errors()[0]["msg"]
    assert expected_env in message
    assert "dummy-secret-key" not in message
    assert "dummy-access-key" not in message


def test_settings_reject_invalid_storage_backend():
    with pytest.raises(ValidationError):
        Settings(_env_file=None, product_image_storage_backend="s3")


@pytest.mark.parametrize("backend_kwargs", [{}, {"product_image_storage_backend": "local"}])
def test_settings_production_rejects_local_storage(backend_kwargs):
    with pytest.raises(ValidationError, match="SPARE_PARTS_PRODUCT_IMAGE_STORAGE_BACKEND='r2'"):
        Settings(
            _env_file=None,
            environment="production",
            database_url="postgresql+psycopg://user:pass@localhost:5432/bmm",
            cookie_secure=True,
            native_https_required=True,
            **backend_kwargs,
        )


@pytest.mark.parametrize(
    "bad_endpoint",
    [
        "ftp://account-id.r2.cloudflarestorage.com",
        "account-id.r2.cloudflarestorage.com",
        "https://user:pass@account-id.r2.cloudflarestorage.com",
        "https://account-id.r2.cloudflarestorage.com/bucket",
        "https://account-id.r2.cloudflarestorage.com?foo=bar",
        "https://account-id.r2.cloudflarestorage.com#frag",
        "https://account-id.r2.cloudflarestorage.com /extra",
        "https://account-id.r2.cloudflarestorage.com:",
        "https://account-id.r2.cloudflarestorage.com:abc",
        "https://account-id.r2.cloudflarestorage.com:99999",
        "https://account-id.r2.cloudflarestorage.com:0",
    ],
)
def test_settings_reject_invalid_r2_endpoint_urls(bad_endpoint):
    with pytest.raises(ValidationError):
        Settings(
            _env_file=None,
            product_image_storage_backend="r2",
            r2_endpoint_url=bad_endpoint,
            r2_bucket="bmm-private-images",
            r2_access_key_id="dummy-access-key",
            r2_secret_access_key="dummy-secret-key",
        )


def test_settings_require_https_r2_endpoint_in_production():
    with pytest.raises(ValidationError, match="HTTPS"):
        Settings(
            _env_file=None,
            environment="production",
            database_url="postgresql+psycopg://user:pass@localhost:5432/bmm",
            cookie_secure=True,
            native_https_required=True,
            product_image_storage_backend="r2",
            r2_endpoint_url="http://account-id.r2.cloudflarestorage.com",
            r2_bucket="bmm-private-images",
            r2_access_key_id="dummy-access-key",
            r2_secret_access_key="dummy-secret-key",
        )

    dev_settings = Settings(
        _env_file=None,
        environment="development",
        product_image_storage_backend="r2",
        r2_endpoint_url="http://localhost:9000",
        r2_bucket="bmm-private-images",
        r2_access_key_id="dummy-access-key",
        r2_secret_access_key="dummy-secret-key",
    )
    assert dev_settings.r2_endpoint_url == "http://localhost:9000"


def test_app_startup_constructs_r2_storage_without_network_calls(tmp_path, test_database_url):
    app = create_app(
        Settings(
            _env_file=None,
            database_url=test_database_url,
            product_image_storage_backend="r2",
            r2_endpoint_url="https://account-id.r2.cloudflarestorage.com",
            r2_bucket="bmm-private-images",
            r2_access_key_id="dummy-access-key",
            r2_secret_access_key="dummy-secret-key",
        )
    )
    assert isinstance(app.state.product_image_storage, R2ProductImageStorage)
    app.state.engine.dispose()


def _create_r2_app(test_database_url: str, mock_s3: MagicMock):
    app = create_app(
        Settings(
            _env_file=None,
            database_url=test_database_url,
            cookie_secure=True,
            product_image_storage_backend="r2",
            r2_endpoint_url="https://account-id.r2.cloudflarestorage.com",
            r2_bucket="bmm-private-images",
            r2_access_key_id="dummy-access-key",
            r2_secret_access_key="dummy-secret-key",
        )
    )
    app.state.product_image_storage = R2ProductImageStorage(
        endpoint_url="https://account-id.r2.cloudflarestorage.com",
        bucket="bmm-private-images",
        access_key_id="dummy-access-key",
        secret_access_key="dummy-secret-key",
        client=mock_s3,
    )
    Base.metadata.create_all(app.state.engine)
    with app.state.session_factory() as session:
        provision_owner(session, "owner@example.test", OWNER_PASSWORD)
        session.commit()
    return app


def _login_owner(client: TestClient) -> dict[str, str]:
    login = client.post(
        "/api/v1/auth/login",
        headers={"Origin": "https://testserver"},
        json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
    )
    assert login.status_code == 200
    return {
        "Origin": "https://testserver",
        "X-CSRF-Token": client.cookies["spare_parts_csrf"],
    }


def test_catalogue_image_replacement_preserves_new_image_when_old_delete_fails(
    test_database_url,
):
    mock_s3 = MagicMock()
    app = _create_r2_app(test_database_url, mock_s3)

    with TestClient(app, base_url="https://testserver", client=("192.0.2.25", 41000)) as client:
        headers = _login_owner(client)
        product = client.post(
            "/api/v1/products",
            headers=headers,
            json={"name": "Oil Filter"},
        ).json()
        first = client.post(
            f"/api/v1/products/{product['id']}/image",
            headers=headers,
            files={"file": ("first.png", _png_bytes(), "image/png")},
        )
        assert first.status_code == 200
        with app.state.session_factory() as session:
            first_key = session.get(Product, UUID(product["id"])).image_key

        mock_s3.delete_object.side_effect = _client_error("InternalError", 500)
        second = client.post(
            f"/api/v1/products/{product['id']}/image",
            headers=headers,
            files={"file": ("second.png", _png_bytes(), "image/png")},
        )
        assert second.status_code == 200
        with app.state.session_factory() as session:
            second_key = session.get(Product, UUID(product["id"])).image_key
        assert second_key is not None
        assert second_key != first_key

        mock_s3.get_object.side_effect = _client_error("InternalError", 500)
        failed_load = client.get(f"/api/v1/products/{product['id']}/image")
        assert failed_load.status_code == 500


def test_catalogue_image_upload_failure_returns_500_without_db_change(test_database_url):
    mock_s3 = MagicMock()
    app = _create_r2_app(test_database_url, mock_s3)

    with TestClient(app, base_url="https://testserver", client=("192.0.2.25", 41000)) as client:
        headers = _login_owner(client)
        product = client.post(
            "/api/v1/products",
            headers=headers,
            json={"name": "Air Filter"},
        ).json()

        mock_s3.put_object.side_effect = _client_error("ServiceUnavailable", 503)
        resp = client.post(
            f"/api/v1/products/{product['id']}/image",
            headers=headers,
            files={"file": ("part.png", _png_bytes(), "image/png")},
        )
        assert resp.status_code == 500
        with app.state.session_factory() as session:
            stored = session.get(Product, UUID(product["id"]))
            assert stored.image_key is None
            assert stored.image_media_type is None


def test_catalogue_image_commit_failure_cleans_up_new_object_and_preserves_old(
    test_database_url,
    monkeypatch,
):
    mock_s3 = MagicMock()
    app = _create_r2_app(test_database_url, mock_s3)

    with TestClient(app, base_url="https://testserver", client=("192.0.2.25", 41000)) as client:
        headers = _login_owner(client)
        product = client.post(
            "/api/v1/products",
            headers=headers,
            json={"name": "Spark Plug"},
        ).json()
        first = client.post(
            f"/api/v1/products/{product['id']}/image",
            headers=headers,
            files={"file": ("first.png", _png_bytes(), "image/png")},
        )
        assert first.status_code == 200
        with app.state.session_factory() as session:
            old_key = session.get(Product, UUID(product["id"])).image_key

        from sqlalchemy.orm import Session

        original_commit = Session.commit
        fail_next = True

        def failing_commit(self):
            nonlocal fail_next
            if fail_next:
                fail_next = False
                raise SQLAlchemyError("simulated commit failure")
            return original_commit(self)

        monkeypatch.setattr(Session, "commit", failing_commit)
        resp = client.post(
            f"/api/v1/products/{product['id']}/image",
            headers=headers,
            files={"file": ("second.png", _png_bytes(), "image/png")},
        )
        assert resp.status_code == 500
        new_key = mock_s3.put_object.call_args_list[-1].kwargs["Key"]
        assert new_key != old_key
        mock_s3.delete_object.assert_called_once_with(
            Bucket="bmm-private-images",
            Key=new_key,
        )
        with app.state.session_factory() as session:
            stored = session.get(Product, UUID(product["id"]))
            assert stored.image_key == old_key
            assert stored.image_media_type == "image/png"


def test_catalogue_image_missing_r2_object_returns_404(test_database_url):
    mock_s3 = MagicMock()
    app = _create_r2_app(test_database_url, mock_s3)

    with TestClient(app, base_url="https://testserver", client=("192.0.2.25", 41000)) as client:
        headers = _login_owner(client)
        product = client.post(
            "/api/v1/products",
            headers=headers,
            json={"name": "Brake Pad"},
        ).json()
        upload = client.post(
            f"/api/v1/products/{product['id']}/image",
            headers=headers,
            files={"file": ("pad.png", _png_bytes(), "image/png")},
        )
        assert upload.status_code == 200

        mock_s3.get_object.side_effect = _client_error("NoSuchKey", 404)
        missing = client.get(f"/api/v1/products/{product['id']}/image")
        assert missing.status_code == 404
