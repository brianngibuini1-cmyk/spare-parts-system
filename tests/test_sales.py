from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
import os
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.auth import provision_owner
from app.config import Settings
from app.database import Base
from app.main import create_app
from app.models import InventoryBalance, Sale, SaleLine, StockMovement

OWNER_PASSWORD = "owner-test-password-at-least-15"
ATTENDANT_PASSWORD = "attendant-test-password-15-plus"


def _csrf_headers(client: TestClient) -> dict[str, str]:
    return {"X-CSRF-Token": client.cookies.get("spare_parts_csrf", "")}


@pytest.fixture
def sales_clients(tmp_path, test_database_url):
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
        assert (
            owner_client.post(
                "/api/v1/auth/login",
                headers={"Origin": "https://testserver"},
                json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
            ).status_code
            == 200
        )
        assert (
            owner_client.post(
                "/api/v1/attendants",
                headers=_csrf_headers(owner_client),
                json={"login_name": "attendant@example.test", "password": ATTENDANT_PASSWORD},
            ).status_code
            == 201
        )
        assert (
            attendant_client.post(
                "/api/v1/auth/login",
                headers={"Origin": "https://testserver"},
                json={"login_name": "attendant@example.test", "password": ATTENDANT_PASSWORD},
            ).status_code
            == 200
        )
        yield app, owner_client, attendant_client


def _create_stocked_product(
    owner_client: TestClient,
    *,
    name: str,
    mpn: str,
    selling_price: str,
    initial_qty: str,
    description: str | None = None,
) -> dict:
    created = owner_client.post(
        "/api/v1/products",
        headers=_csrf_headers(owner_client),
        json={
            "name": name,
            "manufacturer_part_number": mpn,
            "description": description,
        },
    )
    assert created.status_code == 201, created.text
    product = owner_client.post(
        f"/api/v1/products/{created.json()['id']}/approve",
        headers=_csrf_headers(owner_client),
        json={"selling_price": selling_price},
    )
    assert product.status_code == 200, product.text
    prod_json = product.json()

    if Decimal(initial_qty) > 0:
        rcp = owner_client.post(
            "/api/v1/inventory/receipts",
            headers=_csrf_headers(owner_client),
            json={
                "idempotency_key": f"seed-{uuid4()}",
                "lines": [{"product_id": prod_json["id"], "quantity": initial_qty, "unit_cost": "100"}],
            },
        )
        assert rcp.status_code == 201, rcp.text
    return prod_json


def test_sale_creation_snapshots_stock_deduction_and_receipt_history(sales_clients):
    app, owner_client, attendant_client = sales_clients

    oil = _create_stocked_product(
        owner_client,
        name="Synthetic Oil 5W30",
        mpn="SO-5W30",
        selling_price="850.25",
        initial_qty="10",
        description="1L bottle",
    )
    plug = _create_stocked_product(
        owner_client,
        name="Spark Plug",
        mpn="SP-1",
        selling_price="300.00",
        initial_qty="8",
    )

    # Attendant creates a multi-line sale with fractional quantity
    sale_resp = attendant_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"sale-{uuid4()}",
            "payment_method": "cash",
            "amount_tendered": "2000.00",
            "notes": "Front counter cash sale",
            "lines": [
                {"product_id": oil["id"], "quantity": "1.5"},
                {"product_id": plug["id"], "quantity": "2"},
            ],
        },
    )
    assert sale_resp.status_code == 201, sale_resp.text
    sale = sale_resp.json()
    # 1.5 * 850.25 = 1275.3750; 2 * 300 = 600.0000; total = 1875.3750; change = 124.6250
    assert sale["receipt_number"].startswith("RCPT-")
    assert sale["status"] == "completed"
    assert sale["total_amount"] == "1875.3750"
    assert sale["amount_tendered"] == "2000.0000"
    assert sale["change_given"] == "124.6250"
    assert sale["sold_by_login"] == "attendant@example.test"
    assert sale["replayed"] is False
    assert len(sale["lines"]) == 2
    assert sale["lines"][0]["line_total"] == "1275.3750"
    assert sale["lines"][1]["line_total"] == "600.0000"

    # Stock deducted atomically and sale movements recorded
    bal_oil = attendant_client.get("/api/v1/inventory/balances", params={"q": "SO-5W30"}).json()["items"][0]
    bal_plug = attendant_client.get("/api/v1/inventory/balances", params={"q": "SP-1"}).json()["items"][0]
    assert bal_oil["quantity_on_hand"] == "8.5000"
    assert bal_plug["quantity_on_hand"] == "6.0000"

    mov_oil = attendant_client.get(f"/api/v1/inventory/products/{oil['id']}/movements").json()
    assert mov_oil["items"][0]["movement_type"] == "sale"
    assert mov_oil["items"][0]["quantity_delta"] == "-1.5000"
    assert mov_oil["items"][0]["source_id"] == sale["id"]
    assert mov_oil["items"][0]["source_reference"] == sale["receipt_number"]

    # Later product edit must NOT rewrite historical sale snapshot
    edit_resp = owner_client.patch(
        f"/api/v1/products/{oil['id']}",
        headers=_csrf_headers(owner_client),
        json={"name": "Synthetic Oil Renamed"},
    )
    assert edit_resp.status_code == 200, edit_resp.text
    with app.state.session_factory() as session:
        from app.models import Product

        oil_row = session.get(Product, UUID(oil["id"]))
        assert oil_row is not None
        oil_row.selling_price = Decimal("9999.0000")
        session.commit()

    fetched = owner_client.get(f"/api/v1/sales/{sale['id']}")
    assert fetched.status_code == 200
    assert fetched.json()["lines"][0]["product_name"] == "Synthetic Oil 5W30"
    assert fetched.json()["lines"][0]["unit_price"] == "850.2500"
    assert fetched.json()["total_amount"] == "1875.3750"

    listed = attendant_client.get("/api/v1/sales", params={"q": sale["receipt_number"]})
    assert listed.status_code == 200
    assert listed.json()["total"] == 1
    assert listed.json()["items"][0]["id"] == sale["id"]


def test_sale_validation_idempotency_and_atomic_rollback(sales_clients):
    app, owner_client, attendant_client = sales_clients

    prod_a = _create_stocked_product(
        owner_client,
        name="Brake Pad",
        mpn="BP-1",
        selling_price="1000.00",
        initial_qty="5",
    )
    prod_b = _create_stocked_product(
        owner_client,
        name="Air Filter",
        mpn="AF-1",
        selling_price="500.00",
        initial_qty="2",
    )
    pending = owner_client.post(
        "/api/v1/products",
        headers=_csrf_headers(owner_client),
        json={"name": "Pending Part"},
    ).json()

    # Client cannot supply extra total_amount field
    extra_total = attendant_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"sale-{uuid4()}",
            "payment_method": "cash",
            "amount_tendered": "1000",
            "total_amount": "1.00",
            "lines": [{"product_id": prod_a["id"], "quantity": "1"}],
        },
    )
    assert extra_total.status_code == 422

    # Duplicate product lines rejected
    dup_lines = attendant_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"sale-{uuid4()}",
            "payment_method": "cash",
            "amount_tendered": "2000",
            "lines": [
                {"product_id": prod_a["id"], "quantity": "1"},
                {"product_id": prod_a["id"], "quantity": "1"},
            ],
        },
    )
    assert dup_lines.status_code == 422

    # Pending product rejected
    pending_resp = attendant_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"sale-{uuid4()}",
            "payment_method": "cash",
            "amount_tendered": "1000",
            "lines": [{"product_id": pending["id"], "quantity": "1"}],
        },
    )
    assert pending_resp.status_code == 422

    # Insufficient payment rejected
    low_pay = attendant_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"sale-{uuid4()}",
            "payment_method": "cash",
            "amount_tendered": "999.99",
            "lines": [{"product_id": prod_a["id"], "quantity": "1"}],
        },
    )
    assert low_pay.status_code == 422

    # Unsupported payment methods rejected (MVP supports only cash and manual mpesa)
    for bad_method in ("card", "bank_transfer", "other"):
        bad_method_resp = attendant_client.post(
            "/api/v1/sales",
            headers=_csrf_headers(attendant_client),
            json={
                "idempotency_key": f"sale-{uuid4()}",
                "payment_method": bad_method,
                "amount_tendered": "1000",
                "lines": [{"product_id": prod_a["id"], "quantity": "1"}],
            },
        )
        assert bad_method_resp.status_code == 422

    # Excess manual M-PESA payment rejected (no change given on non-cash)
    excess_mpesa = attendant_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"sale-{uuid4()}",
            "payment_method": "mpesa",
            "amount_tendered": "1200",
            "payment_reference": "MPE-EXCESS",
            "lines": [{"product_id": prod_a["id"], "quantity": "1"}],
        },
    )
    assert excess_mpesa.status_code == 422

    # Multi-line rollback when line 2 has insufficient stock (requesting 3 when only 2 available)
    rollback_resp = attendant_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"sale-{uuid4()}",
            "payment_method": "mpesa",
            "amount_tendered": "3500",
            "lines": [
                {"product_id": prod_a["id"], "quantity": "2"},
                {"product_id": prod_b["id"], "quantity": "3"},
            ],
        },
    )
    assert rollback_resp.status_code == 409

    with app.state.session_factory() as session:
        assert session.scalars(select(Sale)).all() == []
        assert session.scalars(select(SaleLine)).all() == []
        assert session.get(InventoryBalance, UUID(prod_a["id"])).quantity_on_hand == Decimal("5.0000")
        assert session.get(InventoryBalance, UUID(prod_b["id"])).quantity_on_hand == Decimal("2.0000")

    # Idempotency replay & conflict with manual M-PESA payment and reference
    idem_key = f"sale-{uuid4()}"
    ok_payload = {
        "idempotency_key": idem_key,
        "payment_method": "mpesa",
        "amount_tendered": "2000",
        "payment_reference": "QWE123XYZ",
        "lines": [{"product_id": prod_a["id"], "quantity": "2"}],
    }
    first = attendant_client.post("/api/v1/sales", headers=_csrf_headers(attendant_client), json=ok_payload)
    assert first.status_code == 201
    assert first.json()["payment_method"] == "mpesa"
    assert first.json()["payment_reference"] == "QWE123XYZ"
    assert first.json()["change_given"] == "0.0000"
    replay = attendant_client.post("/api/v1/sales", headers=_csrf_headers(attendant_client), json=ok_payload)
    assert replay.status_code == 200
    assert replay.json()["replayed"] is True
    assert replay.json()["id"] == first.json()["id"]
    assert replay.json()["receipt_number"] == first.json()["receipt_number"]

    mismatch = attendant_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(attendant_client),
        json={**ok_payload, "lines": [{"product_id": prod_a["id"], "quantity": "3"}]},
    )
    assert mismatch.status_code == 409

    with app.state.session_factory() as session:
        assert session.get(InventoryBalance, UUID(prod_a["id"])).quantity_on_hand == Decimal("3.0000")


def test_postgresql_concurrent_sales_oversell_and_idempotency(tmp_path):
    pg_url = os.environ.get("SPARE_PARTS_TEST_DATABASE_URL")
    if not pg_url:
        pytest.skip("SPARE_PARTS_TEST_DATABASE_URL not configured")

    app = create_app(
        Settings(
            database_url=pg_url,
            cookie_secure=True,
            product_image_storage_path=str(tmp_path / "pg-sales-images"),
        )
    )
    Base.metadata.drop_all(app.state.engine)
    Base.metadata.create_all(app.state.engine)
    with app.state.session_factory() as session:
        provision_owner(session, "owner@example.test", OWNER_PASSWORD)
        session.commit()

    with TestClient(app, base_url="https://testserver", client=("192.0.2.60", 41000)) as client:
        assert (
            client.post(
                "/api/v1/auth/login",
                headers={"Origin": "https://testserver"},
                json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
            ).status_code
            == 200
        )
        prod_oversell = _create_stocked_product(
            client,
            name="Concurrent Clutch",
            mpn="CC-1",
            selling_price="1000",
            initial_qty="10",
        )
        prod_idem = _create_stocked_product(
            client,
            name="Concurrent Hose",
            mpn="CH-1",
            selling_price="400",
            initial_qty="10",
        )

    # 1. Oversell race: two concurrent sales of 7 units each against 10 in stock
    barrier_oversell = Barrier(2)

    def race_sale(idx: int) -> int:
        with TestClient(app, base_url="https://testserver", client=("192.0.2.61", 41000 + idx)) as c:
            c.post(
                "/api/v1/auth/login",
                headers={"Origin": "https://testserver"},
                json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
            )
            barrier_oversell.wait(timeout=10)
            resp = c.post(
                "/api/v1/sales",
                headers=_csrf_headers(c),
                json={
                    "idempotency_key": f"oversell-{idx}-{uuid4()}",
                    "payment_method": "cash",
                    "amount_tendered": "7000",
                    "lines": [{"product_id": prod_oversell["id"], "quantity": "7"}],
                },
            )
            return resp.status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        oversell_statuses = sorted(f.result() for f in [pool.submit(race_sale, i) for i in range(2)])

    assert oversell_statuses == [201, 409]

    # 2. Idempotency race: 4 concurrent identical sale submissions with same key
    shared_key = f"sale-idem-{uuid4()}"
    barrier_idem = Barrier(4)

    def race_idem(idx: int) -> tuple[int, str, bool]:
        with TestClient(app, base_url="https://testserver", client=("192.0.2.62", 42000 + idx)) as c:
            c.post(
                "/api/v1/auth/login",
                headers={"Origin": "https://testserver"},
                json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
            )
            barrier_idem.wait(timeout=10)
            resp = c.post(
                "/api/v1/sales",
                headers=_csrf_headers(c),
                json={
                    "idempotency_key": shared_key,
                    "payment_method": "cash",
                    "amount_tendered": "1200",
                    "lines": [{"product_id": prod_idem["id"], "quantity": "3"}],
                },
            )
            data = resp.json()
            return resp.status_code, data["id"], data["replayed"]

    with ThreadPoolExecutor(max_workers=4) as pool:
        idem_results = [f.result() for f in [pool.submit(race_idem, i) for i in range(4)]]

    assert sorted(r[0] for r in idem_results) == [200, 200, 200, 201]
    assert len({r[1] for r in idem_results}) == 1

    with app.state.session_factory() as session:
        bal_over = session.get(InventoryBalance, UUID(prod_oversell["id"]))
        bal_idem = session.get(InventoryBalance, UUID(prod_idem["id"]))
        assert bal_over is not None and bal_over.quantity_on_hand == Decimal("3.0000")
        assert bal_idem is not None and bal_idem.quantity_on_hand == Decimal("7.0000")
        mov_over = session.scalars(
            select(StockMovement).where(StockMovement.product_id == UUID(prod_oversell["id"]))
        ).all()
        assert sum((m.quantity_delta for m in mov_over), Decimal("0.0000")) == Decimal("3.0000")
        all_sales = session.scalars(select(Sale)).all()
        assert len(all_sales) == 2
        assert len({s.receipt_number for s in all_sales}) == 2
