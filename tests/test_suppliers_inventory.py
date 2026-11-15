from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from decimal import Context, Decimal, localcontext
import os
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.auth import provision_owner
from app.config import Settings
from app.database import Base
from app.inventory_service import MAX_DECIMAL_18_4, quantize_decimal_4
from app.main import create_app
from app.models import GoodsReceipt, InventoryBalance, Product, StockMovement

OWNER_PASSWORD = "owner-test-password-at-least-15"
ATTENDANT_PASSWORD = "attendant-test-password-15-plus"


def _csrf_headers(client: TestClient) -> dict[str, str]:
    return {"X-CSRF-Token": client.cookies.get("spare_parts_csrf", "")}


@pytest.fixture
def inventory_clients(tmp_path, test_database_url):
    app = create_app(
        Settings(
            database_url=test_database_url,
            cookie_secure=True,
            product_image_storage_path=str(tmp_path / "private-images"),
        )
    )
    Base.metadata.create_all(app.state.engine)
    with app.state.session_factory() as session:
        provision_owner(session, "owner@example.test", OWNER_PASSWORD)
        session.commit()

    owner_client = TestClient(app, base_url="https://testserver", client=("192.0.2.25", 41000))
    attendant_client = TestClient(app, base_url="https://testserver", client=("192.0.2.26", 41001))

    with owner_client, attendant_client:
        owner_login = owner_client.post(
            "/api/v1/auth/login",
            headers={"Origin": "https://testserver"},
            json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
        )
        assert owner_login.status_code == 200

        attendant_create = owner_client.post(
            "/api/v1/attendants",
            headers=_csrf_headers(owner_client),
            json={"login_name": "attendant@example.test", "password": ATTENDANT_PASSWORD},
        )
        assert attendant_create.status_code == 201

        attendant_login = attendant_client.post(
            "/api/v1/auth/login",
            headers={"Origin": "https://testserver"},
            json={"login_name": "attendant@example.test", "password": ATTENDANT_PASSWORD},
        )
        assert attendant_login.status_code == 200

        yield app, owner_client, attendant_client


def _create_approved_product(
    owner_client: TestClient,
    *,
    name: str = "Oil Filter X100",
    mpn: str | None = "OF-100",
    selling_price: str = "1250.00",
) -> dict:
    created = owner_client.post(
        "/api/v1/products",
        headers=_csrf_headers(owner_client),
        json={
            "name": name,
            "manufacturer_part_number": mpn,
        },
    )
    assert created.status_code == 201, created.text
    product = created.json()
    approved = owner_client.post(
        f"/api/v1/products/{product['id']}/approve",
        headers=_csrf_headers(owner_client),
        json={"selling_price": selling_price},
    )
    assert approved.status_code == 200, approved.text
    return approved.json()


def _create_pending_product(owner_client: TestClient, *, name: str = "Pending Gasket") -> dict:
    created = owner_client.post(
        "/api/v1/products",
        headers=_csrf_headers(owner_client),
        json={"name": name},
    )
    assert created.status_code == 201, created.text
    return created.json()


def test_supplier_crud_duplicate_normalization_and_deactivation(inventory_clients):
    _, owner_client, _ = inventory_clients

    created = owner_client.post(
        "/api/v1/suppliers",
        headers=_csrf_headers(owner_client),
        json={
            "name": "  Nairobi   Auto Spares Ltd ",
            "contact_person": "Jane Doe",
            "phone": "+254700123456",
            "email": "sales@nairobiauto.example",
            "notes": "Brake and suspension wholesaler",
        },
    )
    assert created.status_code == 201, created.text
    supplier = created.json()
    assert supplier["name"] == "Nairobi   Auto Spares Ltd"
    assert supplier["is_active"] is True

    # Normalized duplicate check (case + whitespace)
    dup = owner_client.post(
        "/api/v1/suppliers",
        headers=_csrf_headers(owner_client),
        json={"name": "nairobi auto spares ltd"},
    )
    assert dup.status_code == 409

    # Edit supplier
    edited = owner_client.patch(
        f"/api/v1/suppliers/{supplier['id']}",
        headers=_csrf_headers(owner_client),
        json={"phone": "+254711999888", "contact_person": "John Doe"},
    )
    assert edited.status_code == 200
    assert edited.json()["phone"] == "+254711999888"
    assert edited.json()["contact_person"] == "John Doe"

    # Deactivate & reactivate
    deactivated = owner_client.post(
        f"/api/v1/suppliers/{supplier['id']}/deactivate",
        headers=_csrf_headers(owner_client),
    )
    assert deactivated.status_code == 200
    assert deactivated.json()["is_active"] is False

    # Search with include_inactive=false hides it, true shows it
    active_only = owner_client.get("/api/v1/suppliers", params={"include_inactive": "false"})
    assert active_only.status_code == 200
    assert active_only.json()["total"] == 0

    all_items = owner_client.get("/api/v1/suppliers", params={"q": "Nairobi", "include_inactive": "true"})
    assert all_items.status_code == 200
    assert all_items.json()["total"] == 1

    reactivated = owner_client.post(
        f"/api/v1/suppliers/{supplier['id']}/activate",
        headers=_csrf_headers(owner_client),
    )
    assert reactivated.status_code == 200
    assert reactivated.json()["is_active"] is True


def test_attendant_supplier_permissions(inventory_clients):
    _, owner_client, attendant_client = inventory_clients

    s1 = owner_client.post(
        "/api/v1/suppliers",
        headers=_csrf_headers(owner_client),
        json={"name": "Active Parts Co"},
    ).json()
    s2 = owner_client.post(
        "/api/v1/suppliers",
        headers=_csrf_headers(owner_client),
        json={"name": "Inactive Parts Co"},
    ).json()
    owner_client.post(
        f"/api/v1/suppliers/{s2['id']}/deactivate",
        headers=_csrf_headers(owner_client),
    )

    # Attendant cannot mutate suppliers
    assert (
        attendant_client.post(
            "/api/v1/suppliers",
            headers=_csrf_headers(attendant_client),
            json={"name": "Unauthorized Supplier"},
        ).status_code
        == 403
    )
    assert (
        attendant_client.patch(
            f"/api/v1/suppliers/{s1['id']}",
            headers=_csrf_headers(attendant_client),
            json={"phone": "123"},
        ).status_code
        == 403
    )
    assert (
        attendant_client.post(
            f"/api/v1/suppliers/{s1['id']}/deactivate",
            headers=_csrf_headers(attendant_client),
        ).status_code
        == 403
    )

    # Attendant can list active suppliers for receiving, and inactive ones are excluded
    listed = attendant_client.get("/api/v1/suppliers", params={"include_inactive": "true"})
    assert listed.status_code == 200
    assert [item["id"] for item in listed.json()["items"]] == [s1["id"]]


def test_goods_receipt_idempotency_and_historical_supplier_preservation(inventory_clients):
    app, owner_client, attendant_client = inventory_clients

    product = _create_approved_product(owner_client, name="Synthetic Motor Oil 5W30", mpn="SMO-5W30")
    supplier = owner_client.post(
        "/api/v1/suppliers",
        headers=_csrf_headers(owner_client),
        json={"name": "Kibo Lubricants"},
    ).json()

    idem_key = f"rcp-{uuid4()}"
    payload = {
        "idempotency_key": idem_key,
        "supplier_id": supplier["id"],
        "delivery_note_reference": "DN-2026-001",
        "notes": "Morning delivery",
        "lines": [
            {
                "product_id": product["id"],
                "quantity": "12.5",
                "unit_cost": "850.25",
            }
        ],
    }

    # Attendant posts receipt
    r1 = attendant_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(attendant_client),
        json=payload,
    )
    assert r1.status_code == 201, r1.text
    body1 = r1.json()
    assert body1["replayed"] is False
    assert body1["supplier_name"] == "Kibo Lubricants"
    assert body1["lines"][0]["quantity"] == "12.5000"
    assert body1["lines"][0]["unit_cost"] == "850.2500"

    # Exact replay returns 200 and does NOT double stock
    r2 = attendant_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(attendant_client),
        json=payload,
    )
    assert r2.status_code == 200, r2.text
    body2 = r2.json()
    assert body2["replayed"] is True
    assert body2["id"] == body1["id"]

    # Same idempotency_key with different payload returns 409 Conflict
    mismatch_payload = {
        **payload,
        "lines": [{"product_id": product["id"], "quantity": "99", "unit_cost": "850.25"}],
    }
    r3 = attendant_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(attendant_client),
        json=mismatch_payload,
    )
    assert r3.status_code == 409

    # Balance is 12.5000 (not 25)
    bal = attendant_client.get("/api/v1/inventory/balances", params={"q": "SMO-5W30"})
    assert bal.status_code == 200
    assert bal.json()["items"][0]["quantity_on_hand"] == "12.5000"

    # Deactivating supplier later does NOT break historical receipt or prevent new unlisted receipt
    owner_client.post(
        f"/api/v1/suppliers/{supplier['id']}/deactivate",
        headers=_csrf_headers(owner_client),
    )
    hist = attendant_client.get(f"/api/v1/inventory/receipts/{body1['id']}")
    assert hist.status_code == 200
    assert hist.json()["supplier_name"] == "Kibo Lubricants"

    # Selecting deactivated supplier for new receipt is rejected
    rejected = attendant_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"rcp-{uuid4()}",
            "supplier_id": supplier["id"],
            "lines": [{"product_id": product["id"], "quantity": "1", "unit_cost": "100"}],
        },
    )
    assert rejected.status_code == 422

    # Unlisted supplier works
    unlisted = attendant_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"rcp-{uuid4()}",
            "unlisted_supplier_name": "Walk-in Vendor",
            "delivery_note_reference": "CASH-99",
            "lines": [{"product_id": product["id"], "quantity": "2.5", "unit_cost": "800"}],
        },
    )
    assert unlisted.status_code == 201
    assert unlisted.json()["unlisted_supplier_name"] == "Walk-in Vendor"

    with app.state.session_factory() as session:
        bal_row = session.get(InventoryBalance, UUID(product["id"]))
        assert bal_row is not None
        assert bal_row.quantity_on_hand == Decimal("15.0000")


def test_receipt_validation_and_atomic_rollback(inventory_clients):
    app, owner_client, attendant_client = inventory_clients

    approved = _create_approved_product(owner_client, name="Brake Pad Set", mpn="BP-200")
    pending = _create_pending_product(owner_client, name="Unapproved Rotor")

    # Rejects both supplier_id and unlisted_supplier_name
    both_suppliers = attendant_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"rcp-{uuid4()}",
            "supplier_id": str(uuid4()),
            "unlisted_supplier_name": "Someone",
            "lines": [{"product_id": approved["id"], "quantity": "1", "unit_cost": "10"}],
        },
    )
    assert both_suppliers.status_code == 422

    # Rejects zero quantity
    zero_qty = attendant_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"rcp-{uuid4()}",
            "lines": [{"product_id": approved["id"], "quantity": "0", "unit_cost": "10"}],
        },
    )
    assert zero_qty.status_code == 422

    # Multi-line receipt where line 2 is pending must roll back line 1 completely
    rollback_resp = attendant_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"rcp-{uuid4()}",
            "lines": [
                {"product_id": approved["id"], "quantity": "5", "unit_cost": "300"},
                {"product_id": pending["id"], "quantity": "2", "unit_cost": "500"},
            ],
        },
    )
    assert rollback_resp.status_code == 422

    with app.state.session_factory() as session:
        assert session.scalars(select(GoodsReceipt)).all() == []
        assert session.scalars(select(StockMovement)).all() == []
        assert session.get(InventoryBalance, UUID(approved["id"])) is None


def test_stock_adjustments_negative_guard_and_movement_history(inventory_clients):
    _, owner_client, attendant_client = inventory_clients

    product = _create_approved_product(owner_client, name="Spark Plug Iridium", mpn="SP-IR1")
    _create_pending_product(owner_client, name="Pending Filter")

    # Approved product starts at 0.0000 in inventory balances; pending product is excluded
    balances = attendant_client.get("/api/v1/inventory/balances")
    assert balances.status_code == 200
    assert balances.json()["total"] == 1
    assert balances.json()["items"][0]["quantity_on_hand"] == "0.0000"

    # Receive 10 units
    attendant_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"rcp-{uuid4()}",
            "unlisted_supplier_name": "Direct Import",
            "delivery_note_reference": "IMP-10",
            "lines": [{"product_id": product["id"], "quantity": "10", "unit_cost": "450"}],
        },
    )

    # Attendant cannot adjust stock
    attendant_adj = attendant_client.post(
        "/api/v1/inventory/adjustments",
        headers=_csrf_headers(attendant_client),
        json={
            "product_id": product["id"],
            "quantity_delta": "-2",
            "reason": "Damaged in bin",
        },
    )
    assert attendant_adj.status_code == 403

    # Negative stock prevention (-11 when on hand is 10)
    over_adj = owner_client.post(
        "/api/v1/inventory/adjustments",
        headers=_csrf_headers(owner_client),
        json={
            "product_id": product["id"],
            "quantity_delta": "-11",
            "reason": "Count variance",
        },
    )
    assert over_adj.status_code == 409

    # Zero delta or blank reason rejected
    assert (
        owner_client.post(
            "/api/v1/inventory/adjustments",
            headers=_csrf_headers(owner_client),
            json={"product_id": product["id"], "quantity_delta": "0", "reason": "Test"},
        ).status_code
        == 422
    )
    assert (
        owner_client.post(
            "/api/v1/inventory/adjustments",
            headers=_csrf_headers(owner_client),
            json={"product_id": product["id"], "quantity_delta": "-1", "reason": "   "},
        ).status_code
        == 422
    )

    # Valid negative adjustment (-2.5)
    adj_ok = owner_client.post(
        "/api/v1/inventory/adjustments",
        headers=_csrf_headers(owner_client),
        json={
            "product_id": product["id"],
            "quantity_delta": "-2.5",
            "reason": "Damaged packaging during shelf audit",
        },
    )
    assert adj_ok.status_code == 201, adj_ok.text
    assert adj_ok.json()["quantity_on_hand"] == "7.5000"
    assert adj_ok.json()["movement"]["movement_type"] == "adjustment"

    # Movement history distinguishes receipt vs adjustment
    history = attendant_client.get(f"/api/v1/inventory/products/{product['id']}/movements")
    assert history.status_code == 200
    hist_json = history.json()
    assert hist_json["quantity_on_hand"] == "7.5000"
    assert hist_json["total"] == 2
    types = [item["movement_type"] for item in hist_json["items"]]
    assert types == ["adjustment", "receipt"]
    assert hist_json["items"][0]["reason"] == "Damaged packaging during shelf audit"
    assert hist_json["items"][1]["supplier_name"] == "Direct Import"
    assert hist_json["items"][1]["source_reference"] == "IMP-10"

    # Ledger immutability: no PATCH or DELETE endpoints on movements or balances
    movement_id = hist_json["items"][0]["id"]
    assert (
        owner_client.delete(
            f"/api/v1/inventory/products/{product['id']}/movements",
            headers=_csrf_headers(owner_client),
        ).status_code
        == 405
    )
    assert (
        owner_client.patch(
            f"/api/v1/inventory/movements/{movement_id}",
            headers=_csrf_headers(owner_client),
            json={"quantity_delta": "100"},
        ).status_code
        == 404
    )


def test_postgresql_concurrent_receipts_and_adjustments(tmp_path):
    pg_url = os.environ.get("SPARE_PARTS_TEST_DATABASE_URL")
    if not pg_url:
        pytest.skip("SPARE_PARTS_TEST_DATABASE_URL not configured")

    app = create_app(
        Settings(
            database_url=pg_url,
            cookie_secure=True,
            product_image_storage_path=str(tmp_path / "pg-images"),
        )
    )
    Base.metadata.drop_all(app.state.engine)
    Base.metadata.create_all(app.state.engine)
    with app.state.session_factory() as session:
        provision_owner(session, "owner@example.test", OWNER_PASSWORD)
        session.commit()

    with TestClient(app, base_url="https://testserver", client=("192.0.2.30", 41000)) as client:
        login = client.post(
            "/api/v1/auth/login",
            headers={"Origin": "https://testserver"},
            json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
        )
        assert login.status_code == 200
        product = _create_approved_product(client, name="Concurrent Bearing", mpn="CB-1")

        # Seed initial 20 units
        seed = client.post(
            "/api/v1/inventory/receipts",
            headers=_csrf_headers(client),
            json={
                "idempotency_key": f"seed-{uuid4()}",
                "lines": [{"product_id": product["id"], "quantity": "20", "unit_cost": "100"}],
            },
        )
        assert seed.status_code == 201

    def worker_receipt(idx: int) -> int:
        with TestClient(app, base_url="https://testserver", client=("192.0.2.31", 41000 + idx)) as c:
            c.post(
                "/api/v1/auth/login",
                headers={"Origin": "https://testserver"},
                json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
            )
            resp = c.post(
                "/api/v1/inventory/receipts",
                headers=_csrf_headers(c),
                json={
                    "idempotency_key": f"conc-rcp-{idx}-{uuid4()}",
                    "lines": [{"product_id": product["id"], "quantity": "3", "unit_cost": "100"}],
                },
            )
            return resp.status_code

    def worker_adjust(idx: int) -> int:
        with TestClient(app, base_url="https://testserver", client=("192.0.2.32", 42000 + idx)) as c:
            c.post(
                "/api/v1/auth/login",
                headers={"Origin": "https://testserver"},
                json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
            )
            resp = c.post(
                "/api/v1/inventory/adjustments",
                headers=_csrf_headers(c),
                json={
                    "product_id": product["id"],
                    "quantity_delta": "-2",
                    "reason": f"Concurrent audit {idx}",
                },
            )
            return resp.status_code

    with ThreadPoolExecutor(max_workers=6) as pool:
        receipt_futures = [pool.submit(worker_receipt, i) for i in range(4)]
        adjust_futures = [pool.submit(worker_adjust, i) for i in range(4)]
        receipt_statuses = [f.result() for f in receipt_futures]
        adjust_statuses = [f.result() for f in adjust_futures]

    assert all(s == 201 for s in receipt_statuses)
    assert all(s == 201 for s in adjust_statuses)

    with app.state.session_factory() as session:
        bal = session.get(InventoryBalance, UUID(product["id"]))
        assert bal is not None
        movements = session.scalars(
            select(StockMovement).where(StockMovement.product_id == UUID(product["id"]))
        ).all()
        ledger_sum = sum((m.quantity_delta for m in movements), Decimal("0.0000"))
        assert bal.quantity_on_hand == Decimal("24.0000")
        assert ledger_sum == bal.quantity_on_hand


def test_successful_multi_line_receipt_and_failure_consistency(inventory_clients):
    app, owner_client, attendant_client = inventory_clients

    prod_a = _create_approved_product(owner_client, name="Coolant Concentrate", mpn="CC-1L")
    prod_b = _create_approved_product(owner_client, name="Timing Belt Kit", mpn="TBK-22")
    supplier = owner_client.post(
        "/api/v1/suppliers",
        headers=_csrf_headers(owner_client),
        json={"name": "Rift Valley Auto Parts"},
    ).json()

    resp = attendant_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"multi-{uuid4()}",
            "supplier_id": supplier["id"],
            "delivery_note_reference": "DN-MULTI-01",
            "notes": "Two-item delivery",
            "lines": [
                {"product_id": prod_a["id"], "quantity": "4.5", "unit_cost": "600"},
                {"product_id": prod_b["id"], "quantity": "3", "unit_cost": "3200.50"},
            ],
        },
    )
    assert resp.status_code == 201, resp.text
    receipt = resp.json()
    assert len(receipt["lines"]) == 2
    assert receipt["lines"][0]["line_number"] == 1
    assert receipt["lines"][1]["line_number"] == 2
    assert receipt["supplier_name"] == "Rift Valley Auto Parts"

    bal_a = attendant_client.get("/api/v1/inventory/balances", params={"q": "CC-1L"}).json()["items"][0]
    bal_b = attendant_client.get("/api/v1/inventory/balances", params={"q": "TBK-22"}).json()["items"][0]
    assert bal_a["quantity_on_hand"] == "4.5000"
    assert bal_b["quantity_on_hand"] == "3.0000"

    mov_a = attendant_client.get(f"/api/v1/inventory/products/{prod_a['id']}/movements").json()
    mov_b = attendant_client.get(f"/api/v1/inventory/products/{prod_b['id']}/movements").json()
    assert mov_a["total"] == 1
    assert mov_b["total"] == 1
    assert mov_a["items"][0]["source_id"] == receipt["id"]
    assert mov_b["items"][0]["source_id"] == receipt["id"]
    assert mov_a["items"][0]["supplier_name"] == "Rift Valley Auto Parts"

    # Failed adjustment must leave movements and balances untouched
    failed_adj = owner_client.post(
        "/api/v1/inventory/adjustments",
        headers=_csrf_headers(owner_client),
        json={
            "product_id": prod_a["id"],
            "quantity_delta": "-5",
            "reason": "Should fail negative check",
        },
    )
    assert failed_adj.status_code == 409

    with app.state.session_factory() as session:
        assert session.get(InventoryBalance, UUID(prod_a["id"])).quantity_on_hand == Decimal("4.5000")
        assert session.get(InventoryBalance, UUID(prod_b["id"])).quantity_on_hand == Decimal("3.0000")
        all_movements = session.scalars(select(StockMovement)).all()
        assert len(all_movements) == 2


def test_postgresql_concurrent_negative_stock_protection(tmp_path):
    pg_url = os.environ.get("SPARE_PARTS_TEST_DATABASE_URL")
    if not pg_url:
        pytest.skip("SPARE_PARTS_TEST_DATABASE_URL not configured")

    app = create_app(
        Settings(
            database_url=pg_url,
            cookie_secure=True,
            product_image_storage_path=str(tmp_path / "pg-neg-images"),
        )
    )
    Base.metadata.drop_all(app.state.engine)
    Base.metadata.create_all(app.state.engine)
    with app.state.session_factory() as session:
        provision_owner(session, "owner@example.test", OWNER_PASSWORD)
        session.commit()

    with TestClient(app, base_url="https://testserver", client=("192.0.2.40", 41000)) as client:
        login = client.post(
            "/api/v1/auth/login",
            headers={"Origin": "https://testserver"},
            json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
        )
        assert login.status_code == 200
        product = _create_approved_product(client, name="Race Condition Seal", mpn="RCS-10")
        seed = client.post(
            "/api/v1/inventory/receipts",
            headers=_csrf_headers(client),
            json={
                "idempotency_key": f"seed-neg-{uuid4()}",
                "lines": [{"product_id": product["id"], "quantity": "10", "unit_cost": "100"}],
            },
        )
        assert seed.status_code == 201

    barrier = Barrier(2)

    def race_adjust(idx: int) -> int:
        with TestClient(app, base_url="https://testserver", client=("192.0.2.41", 41000 + idx)) as c:
            c.post(
                "/api/v1/auth/login",
                headers={"Origin": "https://testserver"},
                json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
            )
            barrier.wait(timeout=10)
            resp = c.post(
                "/api/v1/inventory/adjustments",
                headers=_csrf_headers(c),
                json={
                    "product_id": product["id"],
                    "quantity_delta": "-7",
                    "reason": f"Concurrent reduction {idx}",
                },
            )
            return resp.status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        statuses = sorted(f.result() for f in [pool.submit(race_adjust, i) for i in range(2)])

    assert statuses == [201, 409]

    with app.state.session_factory() as session:
        bal = session.get(InventoryBalance, UUID(product["id"]))
        assert bal is not None
        assert bal.quantity_on_hand == Decimal("3.0000")
        movements = session.scalars(
            select(StockMovement).where(StockMovement.product_id == UUID(product["id"]))
        ).all()
        assert len(movements) == 2
        assert sum((m.quantity_delta for m in movements), Decimal("0.0000")) == Decimal("3.0000")


def test_postgresql_concurrent_receipt_idempotency(tmp_path):
    pg_url = os.environ.get("SPARE_PARTS_TEST_DATABASE_URL")
    if not pg_url:
        pytest.skip("SPARE_PARTS_TEST_DATABASE_URL not configured")

    app = create_app(
        Settings(
            database_url=pg_url,
            cookie_secure=True,
            product_image_storage_path=str(tmp_path / "pg-idem-images"),
        )
    )
    Base.metadata.drop_all(app.state.engine)
    Base.metadata.create_all(app.state.engine)
    with app.state.session_factory() as session:
        provision_owner(session, "owner@example.test", OWNER_PASSWORD)
        session.commit()

    with TestClient(app, base_url="https://testserver", client=("192.0.2.50", 41000)) as client:
        login = client.post(
            "/api/v1/auth/login",
            headers={"Origin": "https://testserver"},
            json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
        )
        assert login.status_code == 200
        product = _create_approved_product(client, name="Idempotent Belt", mpn="IB-55")

    shared_key = f"conc-idem-{uuid4()}"
    barrier = Barrier(4)

    def submit_same_key(idx: int) -> tuple[int, str, bool]:
        with TestClient(app, base_url="https://testserver", client=("192.0.2.51", 41000 + idx)) as c:
            c.post(
                "/api/v1/auth/login",
                headers={"Origin": "https://testserver"},
                json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
            )
            barrier.wait(timeout=10)
            resp = c.post(
                "/api/v1/inventory/receipts",
                headers=_csrf_headers(c),
                json={
                    "idempotency_key": shared_key,
                    "delivery_note_reference": "DN-CONC-1",
                    "lines": [{"product_id": product["id"], "quantity": "5", "unit_cost": "250"}],
                },
            )
            data = resp.json()
            return resp.status_code, data["id"], data["replayed"]

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = [f.result() for f in [pool.submit(submit_same_key, i) for i in range(4)]]

    statuses = sorted(r[0] for r in results)
    receipt_ids = {r[1] for r in results}
    assert statuses == [200, 200, 200, 201]
    assert len(receipt_ids) == 1
    assert sum(1 for r in results if not r[2]) == 1
    assert sum(1 for r in results if r[2]) == 3

    # Retry with same key & same payload -> 200 replayed; different payload -> 409
    with TestClient(app, base_url="https://testserver", client=("192.0.2.52", 41000)) as client:
        client.post(
            "/api/v1/auth/login",
            headers={"Origin": "https://testserver"},
            json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
        )
        retry = client.post(
            "/api/v1/inventory/receipts",
            headers=_csrf_headers(client),
            json={
                "idempotency_key": shared_key,
                "delivery_note_reference": "DN-CONC-1",
                "lines": [{"product_id": product["id"], "quantity": "5", "unit_cost": "250"}],
            },
        )
        assert retry.status_code == 200
        assert retry.json()["replayed"] is True
        assert retry.json()["id"] in receipt_ids

        conflict = client.post(
            "/api/v1/inventory/receipts",
            headers=_csrf_headers(client),
            json={
                "idempotency_key": shared_key,
                "delivery_note_reference": "DN-CONC-1",
                "lines": [{"product_id": product["id"], "quantity": "9", "unit_cost": "250"}],
            },
        )
        assert conflict.status_code == 409

    with app.state.session_factory() as session:
        receipts = session.scalars(select(GoodsReceipt)).all()
        movements = session.scalars(
            select(StockMovement).where(StockMovement.product_id == UUID(product["id"]))
        ).all()
        bal = session.get(InventoryBalance, UUID(product["id"]))
        assert len(receipts) == 1
        assert len(movements) == 1
        assert bal is not None
        assert bal.quantity_on_hand == Decimal("5.0000")


def test_quantize_decimal_4_validation_and_range_checks():
    assert quantize_decimal_4("10", field_name="quantity") == Decimal("10.0000")
    assert quantize_decimal_4("10.5", field_name="quantity") == Decimal("10.5000")
    assert quantize_decimal_4("10.123400", field_name="quantity") == Decimal("10.1234")
    assert quantize_decimal_4(MAX_DECIMAL_18_4, field_name="quantity") == MAX_DECIMAL_18_4
    assert quantize_decimal_4(-MAX_DECIMAL_18_4, field_name="quantity_delta") == -MAX_DECIMAL_18_4

    for bad_precision in ("1.23456", Decimal("0.00001"), "-2.00001"):
        with pytest.raises(HTTPException) as exc:
            quantize_decimal_4(bad_precision, field_name="quantity")
        assert exc.value.status_code == 422

    for out_of_range in (
        "100000000000000.0000",
        "-100000000000000.0000",
        "1" + "0" * 30,
        "1e30",
    ):
        with pytest.raises(HTTPException) as exc:
            quantize_decimal_4(out_of_range, field_name="quantity")
        assert exc.value.status_code == 422

    for non_numeric in ("abc", "NaN", "Infinity", Decimal("-Infinity")):
        with pytest.raises(HTTPException) as exc:
            quantize_decimal_4(non_numeric, field_name="quantity")
        assert exc.value.status_code == 422

    # Force decimal.InvalidOperation inside Decimal.quantize() under a low-precision context
    with localcontext(Context(prec=4)):
        with pytest.raises(HTTPException) as exc:
            quantize_decimal_4(Decimal("12345.0"), field_name="quantity")
        assert exc.value.status_code == 422


def test_invalid_decimal_receipt_and_adjustment_return_422_without_mutations(inventory_clients):
    app, owner_client, _ = inventory_clients
    product = _create_approved_product(owner_client, name="Precision Gasket", mpn="PG-4")

    seed = owner_client.post(
        "/api/v1/inventory/receipts",
        headers=_csrf_headers(owner_client),
        json={
            "idempotency_key": f"seed-prec-{uuid4()}",
            "lines": [{"product_id": product["id"], "quantity": "5", "unit_cost": "100"}],
        },
    )
    assert seed.status_code == 201

    invalid_receipt_payloads = [
        {"product_id": product["id"], "quantity": "1.23456", "unit_cost": "100"},
        {"product_id": product["id"], "quantity": "1", "unit_cost": "100.12345"},
        {"product_id": product["id"], "quantity": "10000000000000000000000000", "unit_cost": "100"},
    ]
    for line in invalid_receipt_payloads:
        resp = owner_client.post(
            "/api/v1/inventory/receipts",
            headers=_csrf_headers(owner_client),
            json={
                "idempotency_key": f"bad-prec-{uuid4()}",
                "lines": [line],
            },
        )
        assert resp.status_code == 422

    for bad_delta in ("-1.00005", "10000000000000000000000000"):
        resp = owner_client.post(
            "/api/v1/inventory/adjustments",
            headers=_csrf_headers(owner_client),
            json={
                "product_id": product["id"],
                "quantity_delta": bad_delta,
                "reason": "Invalid decimal precision test",
            },
        )
        assert resp.status_code == 422

    with app.state.session_factory() as session:
        bal = session.get(InventoryBalance, UUID(product["id"]))
        movements = session.scalars(
            select(StockMovement).where(StockMovement.product_id == UUID(product["id"]))
        ).all()
        receipts = session.scalars(select(GoodsReceipt)).all()
        assert bal is not None
        assert bal.quantity_on_hand == Decimal("5.0000")
        assert len(movements) == 1
        assert len(receipts) == 1
