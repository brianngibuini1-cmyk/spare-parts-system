from __future__ import annotations

import io
import re
from decimal import Decimal
from uuid import UUID

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy.exc import IntegrityError

from app.auth import provision_owner
from app.config import Settings
from app.database import Base
from app.main import BASE_DIR, create_app
from app.models import (
    AuthSession,
    NativeAuthSession,
    NativeRefreshToken,
    Product,
    ProductEvent,
    UserAccount,
)

OWNER_PASSWORD = "owner-test-password-at-least-15"
ATTENDANT_PASSWORD = "attendant-test-password-15-plus"


@pytest.fixture
def owner_client(tmp_path, test_database_url):
    app = create_app(
        Settings(
            database_url=test_database_url,
            cookie_secure=True,
            product_image_storage_path=str(tmp_path / "private-images"),
            product_image_max_bytes=1024,
            product_image_max_pixels=1_000_000,
        )
    )
    Base.metadata.create_all(app.state.engine)
    with app.state.session_factory() as session:
        provision_owner(session, "owner@example.test", OWNER_PASSWORD)
        session.commit()
    with TestClient(app, base_url="https://testserver", client=("192.0.2.25", 41000)) as client:
        response = client.post(
            "/api/v1/auth/login",
            headers={"Origin": "https://testserver"},
            json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
        )
        assert response.status_code == 200
        yield client


def _mutating_headers(client):
    return {"X-CSRF-Token": client.cookies.get("spare_parts_csrf", "")}


def _create_product(client, **overrides):
    payload = {"name": "Clutch release bearing"}
    payload.update(overrides)
    return client.post("/api/v1/products", headers=_mutating_headers(client), json=payload)


def _image_bytes(image_format: str) -> bytes:
    image = Image.new("RGB", (12, 10), (72, 120, 180))
    output = io.BytesIO()
    image.save(output, format=image_format)
    return output.getvalue()


def _new_attendant_client(owner_client):
    response = owner_client.post(
        "/api/v1/attendants",
        headers=_mutating_headers(owner_client),
        json={"login_name": "attendant@example.test", "password": ATTENDANT_PASSWORD},
    )
    assert response.status_code == 201
    attendant = TestClient(
        owner_client.app,
        base_url="https://testserver",
        client=("198.51.100.14", 42000),
    )
    login = attendant.post(
        "/api/v1/auth/login",
        headers={"Origin": "https://testserver"},
        json={"login_name": "attendant@example.test", "password": ATTENDANT_PASSWORD},
    )
    assert login.status_code == 200
    return attendant


def test_product_creation_fields_internal_reference_and_persistence(owner_client):
    response = _create_product(owner_client, category="Transmission", manufacturer_part_number="MP-42")

    assert response.status_code == 201
    product = response.json()
    assert re.fullmatch(r"SP-[A-F0-9]{32}", product["internal_reference"])
    assert product["approval_status"] == "pending"
    assert product["selling_price"] is None
    assert product["description"] is None
    assert product["submitted_by_login"] == "owner@example.test"
    with owner_client.app.state.session_factory() as session:
        saved = session.get(Product, UUID(product["id"]))
        assert saved is not None
        assert saved.name == "Clutch release bearing"
        assert saved.category == "Transmission"
        assert saved.manufacturer_part_number == "MP-42"
        assert session.query(ProductEvent).filter_by(product_id=saved.id, event_type="submitted").count() == 1


def test_required_name_and_optional_fields_validation(owner_client):
    missing_name = owner_client.post(
        "/api/v1/products", headers=_mutating_headers(owner_client), json={"category": "Brakes"}
    )
    blank_name = _create_product(owner_client, name="   ")
    assert missing_name.status_code == 422
    assert blank_name.status_code == 422

    minimal = _create_product(owner_client, name="Oil filter")
    assert minimal.status_code == 201
    assert minimal.json()["category"] is None
    assert minimal.json()["manufacturer_part_number"] is None


def test_duplicate_manufacturer_part_numbers_are_allowed(owner_client):
    first = _create_product(owner_client, name="Oil filter A", manufacturer_part_number="OEM-55")
    second = _create_product(owner_client, name="Oil filter B", manufacturer_part_number="OEM-55")

    assert first.status_code == 201
    assert second.status_code == 201
    assert first.json()["id"] != second.json()["id"]


def test_product_retrieval_and_search(owner_client):
    first = _create_product(owner_client, name="Front brake pad", category="Brakes").json()
    second = _create_product(owner_client, name="Oil filter", category="Engine").json()

    retrieved = owner_client.get(f"/api/v1/products/{first['id']}")
    searched = owner_client.get("/api/v1/products", params={"q": "brake"})

    assert retrieved.status_code == 200
    assert retrieved.json()["name"] == "Front brake pad"
    assert [item["id"] for item in searched.json()["items"]] == [first["id"]]
    assert second["id"] not in [item["id"] for item in searched.json()["items"]]


def test_product_update_omitted_name_preserves_name_and_explicit_null_is_rejected(owner_client):
    product = _create_product(owner_client, name="Alternator belt").json()
    path = f"/api/v1/products/{product['id']}"

    description_update = owner_client.patch(
        path,
        headers=_mutating_headers(owner_client),
        json={"description": "Updated fitment information."},
    )
    explicit_null = owner_client.patch(
        path,
        headers=_mutating_headers(owner_client),
        json={"name": None},
    )

    assert description_update.status_code == 200
    assert description_update.json()["name"] == "Alternator belt"
    assert explicit_null.status_code == 422
    assert owner_client.get(path).json()["name"] == "Alternator belt"


@pytest.mark.parametrize("media_type", ["image/jpeg", "image/png", "image/webp"])
def test_product_image_media_type_constraint_accepts_supported_types(owner_client, media_type):
    product = _create_product(owner_client, name=f"Supported {media_type}").json()
    with owner_client.app.state.session_factory() as session:
        stored = session.get(Product, UUID(product["id"]))
        stored.image_media_type = media_type
        session.commit()


def test_product_image_media_type_constraint_rejects_unsupported_type(owner_client):
    product = _create_product(owner_client, name="Unsupported image type").json()
    with owner_client.app.state.session_factory() as session:
        stored = session.get(Product, UUID(product["id"]))
        stored.image_media_type = "image/svg+xml"
        with pytest.raises(IntegrityError):
            session.commit()
        session.rollback()


def test_database_rejects_invalid_product_approval_state(owner_client):
    with owner_client.app.state.session_factory() as session:
        owner = session.query(UserAccount).filter_by(role="owner").one()
        invalid = Product(
            internal_reference="SP-INVALID",
            name="Invalid approved item",
            approval_status="approved",
            submitted_by=owner.id,
        )
        session.add(invalid)
        with pytest.raises(IntegrityError):
            session.commit()
        session.rollback()


def test_owner_approval_and_price_validation(owner_client):
    product = _create_product(owner_client).json()
    path = f"/api/v1/products/{product['id']}/approve"
    for invalid_price in ("-0.01", "100.00001", "100000000000000.0000", "NaN"):
        response = owner_client.post(
            path, headers=_mutating_headers(owner_client), json={"selling_price": invalid_price}
        )
        assert response.status_code == 422

    approved = owner_client.post(
        path, headers=_mutating_headers(owner_client), json={"selling_price": "2450.1250"}
    )
    assert approved.status_code == 200
    assert approved.json()["approval_status"] == "approved"
    assert approved.json()["selling_price"] == "2450.1250"
    assert approved.json()["approved_by_login"] == "owner@example.test"
    assert approved.json()["approved_at"]
    with owner_client.app.state.session_factory() as session:
        saved = session.get(Product, UUID(product["id"]))
        assert saved.selling_price == Decimal("2450.1250")
        assert saved.approved_by == saved.submitted_by


def test_owner_can_reject_with_reason_and_submission_history_remains(owner_client):
    product = _create_product(owner_client).json()
    response = owner_client.post(
        f"/api/v1/products/{product['id']}/reject",
        headers=_mutating_headers(owner_client),
        json={"reason": "Please verify the part description."},
    )

    assert response.status_code == 200
    assert response.json()["approval_status"] == "rejected"
    assert response.json()["rejection_reason"] == "Please verify the part description."
    with owner_client.app.state.session_factory() as session:
        saved = session.get(Product, UUID(product["id"]))
        assert saved is not None
        assert session.query(ProductEvent).filter_by(product_id=saved.id, event_type="rejected").count() == 1


def test_attendant_can_submit_and_edit_own_pending_products_but_cannot_approve(owner_client):
    attendant = _new_attendant_client(owner_client)
    try:
        response = _create_product(attendant, name="Water pump")
        assert response.status_code == 201
        product = response.json()
        assert product["approval_status"] == "pending"
        assert product["submitted_by_login"] == "attendant@example.test"

        updated = attendant.patch(
            f"/api/v1/products/{product['id']}",
            headers=_mutating_headers(attendant),
            json={"description": "For test vehicle fitment only."},
        )
        assert updated.status_code == 200
        assert updated.json()["description"] == "For test vehicle fitment only."
        assert attendant.post(
            f"/api/v1/products/{product['id']}/approve",
            headers=_mutating_headers(attendant),
            json={"selling_price": "100.00"},
        ).status_code == 403
        assert attendant.get("/api/v1/products/pending").status_code == 403
        assert attendant.get("/api/v1/attendants").status_code == 403
        assert _create_product(attendant, name="Injected price", selling_price="2.00").status_code == 422

        owner_approved = owner_client.post(
            f"/api/v1/products/{product['id']}/approve",
            headers=_mutating_headers(owner_client),
            json={"selling_price": "18.50"},
        )
        assert owner_approved.status_code == 200
        listed = attendant.get("/api/v1/products").json()["items"]
        assert any(row["id"] == product["id"] and row["approval_status"] == "approved" for row in listed)
    finally:
        attendant.close()


def test_attendant_cannot_edit_another_users_submission(owner_client):
    pending = _create_product(owner_client, name="Owner draft").json()
    attendant = _new_attendant_client(owner_client)
    try:
        response = attendant.patch(
            f"/api/v1/products/{pending['id']}",
            headers=_mutating_headers(attendant),
            json={"name": "Changed by attendant"},
        )
        assert response.status_code == 404
    finally:
        attendant.close()


@pytest.mark.parametrize("image_format,mime,filename", [
    ("JPEG", "text/plain", "../../not-trusted.svg"),
    ("PNG", "application/octet-stream", "part.png"),
    ("WEBP", "image/jpeg", "part.jpg"),
])
def test_supported_images_are_validated_from_bytes_and_stored_privately(
    owner_client, image_format, mime, filename
):
    product = _create_product(owner_client, name=f"Image part {image_format}").json()
    response = owner_client.post(
        f"/api/v1/products/{product['id']}/image",
        headers=_mutating_headers(owner_client),
        files={"file": (filename, _image_bytes(image_format), mime)},
    )

    assert response.status_code == 200
    saved = response.json()
    assert saved["image_url"].endswith("/image")
    image = owner_client.get(saved["image_url"])
    assert image.status_code == 200
    assert image.headers["content-type"].startswith({"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}[image_format])
    with owner_client.app.state.session_factory() as session:
        stored = session.get(Product, UUID(product["id"]))
        path = owner_client.app.state.product_image_storage.root / stored.image_key
        assert path.is_file()
        assert not owner_client.app.state.product_image_storage.root.is_relative_to(BASE_DIR / "static")


def test_invalid_svg_and_oversized_image_are_rejected(owner_client):
    product = _create_product(owner_client, name="Image validation part").json()
    path = f"/api/v1/products/{product['id']}/image"
    svg = owner_client.post(
        path,
        headers=_mutating_headers(owner_client),
        files={"file": ("part.jpg", b"<svg xmlns='http://www.w3.org/2000/svg'></svg>", "image/jpeg")},
    )
    oversized = owner_client.post(
        path,
        headers=_mutating_headers(owner_client),
        files={"file": ("part.jpg", b"x" * 1025, "image/jpeg")},
    )
    assert svg.status_code == 415
    assert oversized.status_code == 413


def test_attendant_cannot_retrieve_another_users_private_pending_image(owner_client):
    product = _create_product(owner_client, name="Private pending image").json()
    upload = owner_client.post(
        f"/api/v1/products/{product['id']}/image",
        headers=_mutating_headers(owner_client),
        files={"file": ("part.png", _image_bytes("PNG"), "image/png")},
    )
    assert upload.status_code == 200
    attendant = _new_attendant_client(owner_client)
    try:
        assert attendant.get(upload.json()["image_url"]).status_code == 404
        assert owner_client.get(upload.json()["image_url"]).status_code == 200
    finally:
        attendant.close()


def test_owner_cannot_upload_or_replace_image_on_rejected_product(owner_client):
    product_with_image = _create_product(owner_client, name="Rejected with image").json()
    initial_upload = owner_client.post(
        f"/api/v1/products/{product_with_image['id']}/image",
        headers=_mutating_headers(owner_client),
        files={"file": ("initial.png", _image_bytes("PNG"), "image/png")},
    )
    assert initial_upload.status_code == 200

    with owner_client.app.state.session_factory() as session:
        original_key = session.get(Product, UUID(product_with_image["id"])).image_key
        assert original_key is not None

    rejected_with_image = owner_client.post(
        f"/api/v1/products/{product_with_image['id']}/reject",
        headers=_mutating_headers(owner_client),
        json={"reason": "Incorrect part specification."},
    )
    assert rejected_with_image.status_code == 200
    assert rejected_with_image.json()["can_edit"] is False

    patch_rejected = owner_client.patch(
        f"/api/v1/products/{product_with_image['id']}",
        headers=_mutating_headers(owner_client),
        json={"name": "Edited after rejection"},
    )
    replace_rejected_image = owner_client.post(
        f"/api/v1/products/{product_with_image['id']}/image",
        headers=_mutating_headers(owner_client),
        files={"file": ("replacement.jpg", _image_bytes("JPEG"), "image/jpeg")},
    )
    assert patch_rejected.status_code == 409
    assert patch_rejected.json() == {"detail": "Rejected products cannot be edited."}
    assert replace_rejected_image.status_code == 409
    assert replace_rejected_image.json() == {"detail": "Rejected products cannot be edited."}

    with owner_client.app.state.session_factory() as session:
        stored = session.get(Product, UUID(product_with_image["id"]))
        assert stored.image_key == original_key
        assert stored.image_media_type == "image/png"
        assert (
            session.query(ProductEvent)
            .filter_by(product_id=stored.id, event_type="image_updated")
            .count()
            == 1
        )

    product_without_image = _create_product(owner_client, name="Rejected without image").json()
    rejected_without_image = owner_client.post(
        f"/api/v1/products/{product_without_image['id']}/reject",
        headers=_mutating_headers(owner_client),
        json={"reason": "Discontinued part."},
    )
    assert rejected_without_image.status_code == 200

    upload_after_reject = owner_client.post(
        f"/api/v1/products/{product_without_image['id']}/image",
        headers=_mutating_headers(owner_client),
        files={"file": ("new.png", _image_bytes("PNG"), "image/png")},
    )
    assert upload_after_reject.status_code == 409
    assert upload_after_reject.json() == {"detail": "Rejected products cannot be edited."}

    with owner_client.app.state.session_factory() as session:
        stored_empty = session.get(Product, UUID(product_without_image["id"]))
        assert stored_empty.image_key is None
        assert (
            session.query(ProductEvent)
            .filter_by(product_id=stored_empty.id, event_type="image_updated")
            .count()
            == 0
        )


def test_attendant_image_upload_authorization_matches_product_update_rules(owner_client):
    attendant = _new_attendant_client(owner_client)
    try:
        own_pending = _create_product(attendant, name="Attendant pending part").json()
        own_upload = attendant.post(
            f"/api/v1/products/{own_pending['id']}/image",
            headers=_mutating_headers(attendant),
            files={"file": ("own.png", _image_bytes("PNG"), "image/png")},
        )
        assert own_upload.status_code == 200
        assert own_upload.json()["can_edit"] is True

        owner_approved = owner_client.post(
            f"/api/v1/products/{own_pending['id']}/approve",
            headers=_mutating_headers(owner_client),
            json={"selling_price": "45.0000"},
        )
        assert owner_approved.status_code == 200

        patch_own_approved = attendant.patch(
            f"/api/v1/products/{own_pending['id']}",
            headers=_mutating_headers(attendant),
            json={"description": "Cannot edit after approval"},
        )
        upload_own_approved = attendant.post(
            f"/api/v1/products/{own_pending['id']}/image",
            headers=_mutating_headers(attendant),
            files={"file": ("after-approve.jpg", _image_bytes("JPEG"), "image/jpeg")},
        )
        assert patch_own_approved.status_code == 403
        assert patch_own_approved.json() == {"detail": "Only your pending submissions can be edited."}
        assert upload_own_approved.status_code == 403
        assert upload_own_approved.json() == {"detail": "Only your pending submissions can be edited."}

        own_to_reject = _create_product(attendant, name="Attendant rejected part").json()
        owner_rejected = owner_client.post(
            f"/api/v1/products/{own_to_reject['id']}/reject",
            headers=_mutating_headers(owner_client),
            json={"reason": "Missing part number."},
        )
        assert owner_rejected.status_code == 200

        patch_own_rejected = attendant.patch(
            f"/api/v1/products/{own_to_reject['id']}",
            headers=_mutating_headers(attendant),
            json={"description": "Cannot edit after rejection"},
        )
        upload_own_rejected = attendant.post(
            f"/api/v1/products/{own_to_reject['id']}/image",
            headers=_mutating_headers(attendant),
            files={"file": ("after-reject.png", _image_bytes("PNG"), "image/png")},
        )
        assert patch_own_rejected.status_code == 403
        assert patch_own_rejected.json() == {"detail": "Only your pending submissions can be edited."}
        assert upload_own_rejected.status_code == 403
        assert upload_own_rejected.json() == {"detail": "Only your pending submissions can be edited."}

        owner_pending = _create_product(owner_client, name="Owner pending part").json()
        owner_approved_part = _create_product(owner_client, name="Owner approved part").json()
        owner_client.post(
            f"/api/v1/products/{owner_approved_part['id']}/approve",
            headers=_mutating_headers(owner_client),
            json={"selling_price": "99.0000"},
        )
        owner_rejected_part = _create_product(owner_client, name="Owner rejected part").json()
        owner_client.post(
            f"/api/v1/products/{owner_rejected_part['id']}/reject",
            headers=_mutating_headers(owner_client),
            json={"reason": "Owner rejected."},
        )

        for other_product in (owner_pending, owner_approved_part, owner_rejected_part):
            upload_other = attendant.post(
                f"/api/v1/products/{other_product['id']}/image",
                headers=_mutating_headers(attendant),
                files={"file": ("other.png", _image_bytes("PNG"), "image/png")},
            )
            assert upload_other.status_code == 404
            assert upload_other.json() == {"detail": "Product not found."}
    finally:
        attendant.close()


def test_product_and_attendant_writes_require_authentication(owner_client):
    anonymous = TestClient(owner_client.app, base_url="https://testserver")
    try:
        assert anonymous.get("/api/v1/products").status_code == 401
        assert anonymous.post("/api/v1/products", json={"name": "No access"}).status_code == 401
        assert anonymous.get("/products").status_code == 401
        assert anonymous.get("/team").status_code == 401
    finally:
        anonymous.close()


@pytest.fixture
def attendant_with_browser_and_native_sessions(owner_client):
    attendant = _new_attendant_client(owner_client)
    native_login = attendant.post(
        "/api/v1/native/auth/login",
        json={"login_name": "attendant@example.test", "password": ATTENDANT_PASSWORD},
    )
    assert native_login.status_code == 200
    yield attendant, native_login.json()
    attendant.close()


def _set_attendant_active(owner_client, is_active):
    with owner_client.app.state.session_factory() as session:
        attendant = session.query(UserAccount).filter_by(role="attendant").one()
        attendant_id = attendant.id
    response = owner_client.patch(
        f"/api/v1/attendants/{attendant_id}",
        headers=_mutating_headers(owner_client),
        json={"is_active": is_active},
    )
    assert response.status_code == 200
    return response


def test_disabling_attendant_revokes_browser_native_and_refresh_sessions(
    owner_client, attendant_with_browser_and_native_sessions
):
    attendant, native_tokens = attendant_with_browser_and_native_sessions
    access_headers = {"Authorization": f"Bearer {native_tokens['access_token']}"}
    assert attendant.get("/api/v1/auth/me").status_code == 200
    assert attendant.get("/api/v1/native/auth/me", headers=access_headers).status_code == 200

    _set_attendant_active(owner_client, False)

    assert attendant.get("/api/v1/auth/me").status_code == 401
    assert attendant.get("/api/v1/native/auth/me", headers=access_headers).status_code == 401
    assert attendant.post(
        "/api/v1/native/auth/refresh",
        json={"refresh_token": native_tokens["refresh_token"]},
    ).status_code == 401
    with owner_client.app.state.session_factory() as session:
        assert session.query(AuthSession).filter(AuthSession.revoked_at.is_not(None)).count() == 1
        native_session = session.query(NativeAuthSession).one()
        assert native_session.revoked_at is not None
        assert session.query(NativeRefreshToken).count() == 1


def test_reactivated_attendant_requires_fresh_browser_and_native_sessions(
    owner_client, attendant_with_browser_and_native_sessions
):
    attendant, native_tokens = attendant_with_browser_and_native_sessions
    old_access_headers = {"Authorization": f"Bearer {native_tokens['access_token']}"}
    _set_attendant_active(owner_client, False)
    _set_attendant_active(owner_client, True)

    assert attendant.get("/api/v1/auth/me").status_code == 401
    assert attendant.get("/api/v1/native/auth/me", headers=old_access_headers).status_code == 401
    assert attendant.post(
        "/api/v1/native/auth/refresh",
        json={"refresh_token": native_tokens["refresh_token"]},
    ).status_code == 401

    browser_login = attendant.post(
        "/api/v1/auth/login",
        headers={"Origin": "https://testserver"},
        json={"login_name": "attendant@example.test", "password": ATTENDANT_PASSWORD},
    )
    native_login = attendant.post(
        "/api/v1/native/auth/login",
        json={"login_name": "attendant@example.test", "password": ATTENDANT_PASSWORD},
    )
    assert browser_login.status_code == 200
    assert attendant.get("/api/v1/auth/me").status_code == 200
    assert native_login.status_code == 200
    assert attendant.get(
        "/api/v1/native/auth/me",
        headers={"Authorization": f"Bearer {native_login.json()['access_token']}"},
    ).status_code == 200
