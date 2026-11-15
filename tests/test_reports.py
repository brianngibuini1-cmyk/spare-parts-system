from __future__ import annotations

from datetime import date, datetime, timezone
from decimal import Decimal
import os
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import update

from app.auth import provision_owner
from app.config import Settings
from app.database import Base
from app.main import create_app
from app.models import InventoryBalance, Sale, StockMovement
from app.reports_service import get_dashboard_summary, get_sales_report

OWNER_PASSWORD = "owner-test-password-at-least-15"
ATTENDANT_PASSWORD = "attendant-test-password-15-plus"


def _csrf_headers(client: TestClient) -> dict[str, str]:
    return {"X-CSRF-Token": client.cookies.get("spare_parts_csrf", "")}


@pytest.fixture
def reports_clients(tmp_path, test_database_url):
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

    owner_client = TestClient(app, base_url="https://testserver", client=("192.0.2.30", 41000))
    attendant_client = TestClient(app, base_url="https://testserver", client=("192.0.2.31", 41001))
    anon_client = TestClient(app, base_url="https://testserver", client=("192.0.2.32", 41002))

    with owner_client, attendant_client, anon_client:
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
        yield app, owner_client, attendant_client, anon_client


def _seed_product(
    owner_client: TestClient,
    *,
    name: str,
    mpn: str,
    selling_price: str,
    initial_qty: str,
) -> dict:
    created = owner_client.post(
        "/api/v1/products",
        headers=_csrf_headers(owner_client),
        json={"name": name, "manufacturer_part_number": mpn},
    )
    assert created.status_code == 201
    approved = owner_client.post(
        f"/api/v1/products/{created.json()['id']}/approve",
        headers=_csrf_headers(owner_client),
        json={"selling_price": selling_price},
    )
    assert approved.status_code == 200
    prod = approved.json()
    if Decimal(initial_qty) > 0:
        rcp = owner_client.post(
            "/api/v1/inventory/receipts",
            headers=_csrf_headers(owner_client),
            json={
                "idempotency_key": f"seed-{uuid4()}",
                "lines": [{"product_id": prod["id"], "quantity": initial_qty, "unit_cost": "100"}],
            },
        )
        assert rcp.status_code == 201
    return prod


def test_dashboard_and_reports_authorization_and_aggregations(reports_clients):
    app, owner_client, attendant_client, anon_client = reports_clients

    # Unauthenticated requests rejected
    assert anon_client.get("/api/v1/dashboard").status_code == 401
    assert anon_client.get("/api/v1/reports/sales").status_code == 401
    assert anon_client.get("/api/v1/reports/inventory/balances").status_code == 401
    assert anon_client.get("/api/v1/reports/inventory/movements").status_code == 401

    # Seed approved products (1 with stock, 1 with zero stock) and 1 pending product
    stocked = _seed_product(
        owner_client,
        name="Brake Rotor",
        mpn="BR-100",
        selling_price="1200.50",
        initial_qty="10",
    )
    _seed_product(
        owner_client,
        name="Out Of Stock Gasket",
        mpn="GS-0",
        selling_price="250.00",
        initial_qty="0",
    )
    pending = owner_client.post(
        "/api/v1/products",
        headers=_csrf_headers(owner_client),
        json={"name": "Pending Spark Plug"},
    )
    assert pending.status_code == 201

    # Create one cash sale and one manual M-PESA sale today
    cash_sale = attendant_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"cash-{uuid4()}",
            "payment_method": "cash",
            "amount_tendered": "3000",
            "lines": [{"product_id": stocked["id"], "quantity": "2"}],
        },
    )
    assert cash_sale.status_code == 201
    mpesa_sale = attendant_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(attendant_client),
        json={
            "idempotency_key": f"mpesa-{uuid4()}",
            "payment_method": "mpesa",
            "amount_tendered": "1200.50",
            "payment_reference": "MPE987XYZ",
            "lines": [{"product_id": stocked["id"], "quantity": "1"}],
        },
    )
    assert mpesa_sale.status_code == 201

    # Both owner and attendant can read dashboard
    owner_dash = owner_client.get("/api/v1/dashboard")
    att_dash = attendant_client.get("/api/v1/dashboard")
    assert owner_dash.status_code == 200
    assert att_dash.status_code == 200
    dash = owner_dash.json()
    assert att_dash.json() == dash
    assert dash["timezone"] == "Africa/Nairobi"
    assert dash["today_completed_sales_count"] == 2
    assert dash["today_sales_total"] == "3601.5000"
    assert dash["today_cash_total"] == "2401.0000"
    assert dash["today_mpesa_total"] == "1200.5000"
    assert dash["approved_products_count"] == 2
    assert dash["zero_stock_products_count"] == 1

    # Attendant cannot access owner-only reports
    assert attendant_client.get("/api/v1/reports/sales").status_code == 403
    assert attendant_client.get("/api/v1/reports/inventory/balances").status_code == 403
    assert attendant_client.get("/api/v1/reports/inventory/movements").status_code == 403

    # Invalid date ranges rejected
    assert (
        owner_client.get(
            "/api/v1/reports/sales",
            params={"from_date": "2026-11-14", "to_date": "2026-11-10"},
        ).status_code
        == 422
    )
    assert (
        owner_client.get(
            "/api/v1/reports/inventory/movements",
            params={"from_date": "2026-11-14", "to_date": "2026-11-10"},
        ).status_code
        == 422
    )

    # Owner sales report
    sales_rep = owner_client.get("/api/v1/reports/sales")
    assert sales_rep.status_code == 200
    sjson = sales_rep.json()
    assert sjson["timezone"] == "Africa/Nairobi"
    assert sjson["completed_sales_count"] == 2
    assert sjson["total_sales_value"] == "3601.5000"
    assert sjson["cash_total"] == "2401.0000"
    assert sjson["mpesa_total"] == "1200.5000"
    assert "not automatically verified" in sjson["mpesa_note"]

    # Owner inventory balances report
    bal_rep = owner_client.get("/api/v1/reports/inventory/balances", params={"limit": 10, "offset": 0})
    assert bal_rep.status_code == 200
    bjson = bal_rep.json()
    assert bjson["total"] == 2
    by_name = {item["name"]: item for item in bjson["items"]}
    assert by_name["Brake Rotor"]["quantity_on_hand"] == "7.0000"
    assert by_name["Brake Rotor"]["unit_of_measure"] is None
    assert by_name["Out Of Stock Gasket"]["quantity_on_hand"] == "0.0000"

    # Owner movement history report + pagination
    mov_page1 = owner_client.get("/api/v1/reports/inventory/movements", params={"limit": 2, "offset": 0})
    assert mov_page1.status_code == 200
    m1 = mov_page1.json()
    assert m1["total"] == 3  # 1 receipt + 2 sales
    assert len(m1["items"]) == 2
    assert m1["items"][0]["actor_login"] == "attendant@example.test"


def test_nairobi_timezone_calendar_day_boundaries(reports_clients):
    app, owner_client, _, _ = reports_clients
    stocked = _seed_product(
        owner_client,
        name="Timing Belt",
        mpn="TB-1",
        selling_price="500.00",
        initial_qty="20",
    )

    # Create two sales and assign timestamps straddling 2026-11-12 / 2026-11-13 in Africa/Nairobi (UTC+3)
    # 2026-11-12 20:59:59 UTC == 2026-11-12 23:59:59 EAT (belongs to Nov 12)
    # 2026-11-12 21:00:00 UTC == 2026-11-13 00:00:00 EAT (belongs to Nov 13)
    s1 = owner_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(owner_client),
        json={
            "idempotency_key": f"tz1-{uuid4()}",
            "payment_method": "cash",
            "amount_tendered": "500",
            "lines": [{"product_id": stocked["id"], "quantity": "1"}],
        },
    ).json()
    s2 = owner_client.post(
        "/api/v1/sales",
        headers=_csrf_headers(owner_client),
        json={
            "idempotency_key": f"tz2-{uuid4()}",
            "payment_method": "mpesa",
            "amount_tendered": "1000",
            "payment_reference": "MPE-TZ2",
            "lines": [{"product_id": stocked["id"], "quantity": "2"}],
        },
    ).json()

    with app.state.session_factory() as session:
        session.execute(
            update(Sale)
            .where(Sale.id == uuid4() if False else Sale.receipt_number == s1["receipt_number"])
            .values(sold_at=datetime(2026, 11, 12, 20, 59, 59, tzinfo=timezone.utc))
        )
        session.execute(
            update(Sale)
            .where(Sale.receipt_number == s2["receipt_number"])
            .values(sold_at=datetime(2026, 11, 12, 21, 0, 0, tzinfo=timezone.utc))
        )
        session.commit()

        nov12 = get_sales_report(
            session,
            from_date=date(2026, 11, 12),
            to_date=date(2026, 11, 12),
        )
        nov13 = get_sales_report(
            session,
            from_date=date(2026, 11, 13),
            to_date=date(2026, 11, 13),
        )
        dash_nov13 = get_dashboard_summary(
            session,
            now=datetime(2026, 11, 12, 21, 5, 0, tzinfo=timezone.utc),
        )

    assert nov12.completed_sales_count == 1
    assert nov12.cash_total == Decimal("500.0000")
    assert nov12.mpesa_total == Decimal("0.0000")

    assert nov13.completed_sales_count == 1
    assert nov13.cash_total == Decimal("0.0000")
    assert nov13.mpesa_total == Decimal("1000.0000")

    assert dash_nov13.business_date == date(2026, 11, 13)
    assert dash_nov13.today_completed_sales_count == 1
    assert dash_nov13.today_mpesa_total == Decimal("1000.0000")


def test_postgresql_dashboard_and_reports(tmp_path):
    pg_url = os.environ.get("SPARE_PARTS_TEST_DATABASE_URL")
    if not pg_url:
        pytest.skip("SPARE_PARTS_TEST_DATABASE_URL not configured")

    app = create_app(
        Settings(
            database_url=pg_url,
            cookie_secure=True,
            product_image_storage_path=str(tmp_path / "pg-reports-images"),
        )
    )
    Base.metadata.drop_all(app.state.engine)
    Base.metadata.create_all(app.state.engine)
    with app.state.session_factory() as session:
        provision_owner(session, "owner@example.test", OWNER_PASSWORD)
        session.commit()

    with TestClient(app, base_url="https://testserver", client=("192.0.2.70", 41000)) as client:
        assert (
            client.post(
                "/api/v1/auth/login",
                headers={"Origin": "https://testserver"},
                json={"login_name": "owner@example.test", "password": OWNER_PASSWORD},
            ).status_code
            == 200
        )
        prod = _seed_product(
            client,
            name="PG Headlight Bulb",
            mpn="PG-H4",
            selling_price="750.00",
            initial_qty="5",
        )
        assert (
            client.post(
                "/api/v1/sales",
                headers=_csrf_headers(client),
                json={
                    "idempotency_key": f"pg-sale-{uuid4()}",
                    "payment_method": "mpesa",
                    "amount_tendered": "1500.00",
                    "payment_reference": "PGMPE1",
                    "lines": [{"product_id": prod["id"], "quantity": "2"}],
                },
            ).status_code
            == 201
        )
        dash = client.get("/api/v1/dashboard")
        assert dash.status_code == 200
        assert dash.json()["today_completed_sales_count"] == 1
        assert dash.json()["today_mpesa_total"] == "1500.0000"
        assert client.get("/api/v1/reports/sales").json()["total_sales_value"] == "1500.0000"
        assert client.get("/api/v1/reports/inventory/balances").json()["items"][0]["quantity_on_hand"] == "3.0000"
        assert client.get("/api/v1/reports/inventory/movements").json()["total"] == 2


def test_reports_empty_dataset_search_date_filters_and_pagination(reports_clients):
    app, owner_client, _, _ = reports_clients

    # 1. Empty dataset checks
    dash_empty = owner_client.get("/api/v1/dashboard")
    assert dash_empty.status_code == 200
    assert dash_empty.json()["today_completed_sales_count"] == 0
    assert dash_empty.json()["today_sales_total"] == "0.0000"
    assert dash_empty.json()["approved_products_count"] == 0
    assert dash_empty.json()["zero_stock_products_count"] == 0

    sales_empty = owner_client.get("/api/v1/reports/sales")
    assert sales_empty.status_code == 200
    assert sales_empty.json()["completed_sales_count"] == 0
    assert sales_empty.json()["total_sales_value"] == "0.0000"

    bal_empty = owner_client.get("/api/v1/reports/inventory/balances")
    assert bal_empty.status_code == 200
    assert bal_empty.json()["total"] == 0
    assert bal_empty.json()["items"] == []

    mov_empty = owner_client.get("/api/v1/reports/inventory/movements")
    assert mov_empty.status_code == 200
    assert mov_empty.json()["total"] == 0
    assert mov_empty.json()["items"] == []

    # 2. Seed 3 products with initial stock (3 receipt movements)
    p1 = _seed_product(owner_client, name="Alpha Pad", mpn="AP-1", selling_price="100", initial_qty="5")
    p2 = _seed_product(owner_client, name="Beta Filter", mpn="BF-2", selling_price="200", initial_qty="6")
    _seed_product(owner_client, name="Gamma Plug", mpn="GP-3", selling_price="300", initial_qty="7")

    # Search inventory balances by name and MPN
    search_bal = owner_client.get("/api/v1/reports/inventory/balances", params={"q": "BF-2"})
    assert search_bal.status_code == 200
    assert search_bal.json()["total"] == 1
    assert search_bal.json()["items"][0]["name"] == "Beta Filter"

    # Paginate inventory balances
    bal_p1 = owner_client.get("/api/v1/reports/inventory/balances", params={"limit": 2, "offset": 0}).json()
    bal_p2 = owner_client.get("/api/v1/reports/inventory/balances", params={"limit": 2, "offset": 2}).json()
    assert bal_p1["total"] == 3 and len(bal_p1["items"]) == 2
    assert bal_p2["total"] == 3 and len(bal_p2["items"]) == 1
    assert [i["name"] for i in bal_p1["items"] + bal_p2["items"]] == [
        "Alpha Pad",
        "Beta Filter",
        "Gamma Plug",
    ]

    # Backdate one movement to Nov 10 (Nairobi) and keep others today
    with app.state.session_factory() as session:
        session.execute(
            update(StockMovement)
            .where(StockMovement.product_id == UUID(p1["id"]))
            .values(created_at=datetime(2026, 11, 10, 12, 0, tzinfo=timezone.utc))
        )
        session.commit()

    # Movement date filter
    mov_nov10 = owner_client.get(
        "/api/v1/reports/inventory/movements",
        params={"from_date": "2026-11-10", "to_date": "2026-11-10"},
    )
    assert mov_nov10.status_code == 200
    assert mov_nov10.json()["total"] == 1
    assert mov_nov10.json()["items"][0]["product_name"] == "Alpha Pad"

    # Movement search filter
    mov_search = owner_client.get("/api/v1/reports/inventory/movements", params={"q": "Gamma"})
    assert mov_search.status_code == 200
    assert mov_search.json()["total"] == 1
    assert mov_search.json()["items"][0]["product_name"] == "Gamma Plug"

    # Movement pagination
    mov_p1 = owner_client.get("/api/v1/reports/inventory/movements", params={"limit": 2, "offset": 0}).json()
    mov_p2 = owner_client.get("/api/v1/reports/inventory/movements", params={"limit": 2, "offset": 2}).json()
    assert mov_p1["total"] == 3 and len(mov_p1["items"]) == 2
    assert mov_p2["total"] == 3 and len(mov_p2["items"]) == 1
    assert len({m["id"] for m in mov_p1["items"] + mov_p2["items"]}) == 3
