"""FastAPI routes for operational dashboard and owner-only basic reports."""

from __future__ import annotations

from datetime import date, datetime

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.auth import AuthContext, get_current_auth, require_owner
from app.database import get_session
from app.inventory_service import ZERO_DECIMAL, format_decimal_4
from app.reports_service import (
    BUSINESS_TIMEZONE_NAME,
    get_dashboard_summary,
    get_sales_report,
    list_report_inventory_balances,
    list_report_stock_movements,
)

dashboard_router = APIRouter(prefix="/api/v1/dashboard", tags=["dashboard"])
reports_router = APIRouter(prefix="/api/v1/reports", tags=["reports"])


class DashboardResponse(BaseModel):
    timezone: str
    business_date: date
    today_completed_sales_count: int
    today_sales_total: str
    today_cash_total: str
    today_mpesa_total: str
    approved_products_count: int
    zero_stock_products_count: int


class SalesReportResponse(BaseModel):
    timezone: str
    from_date: date
    to_date: date
    completed_sales_count: int
    total_sales_value: str
    cash_total: str
    mpesa_total: str
    mpesa_note: str


class ReportInventoryBalanceItem(BaseModel):
    product_id: str
    internal_reference: str
    name: str
    manufacturer_part_number: str | None
    unit_of_measure: str | None
    selling_price: str
    quantity_on_hand: str
    updated_at: datetime | None


class ReportInventoryBalanceListResponse(BaseModel):
    items: list[ReportInventoryBalanceItem]
    total: int
    limit: int
    offset: int


class ReportStockMovementItem(BaseModel):
    id: str
    product_id: str
    product_internal_reference: str
    product_name: str
    movement_type: str
    quantity_delta: str
    source_type: str
    source_id: str
    source_reference: str | None
    reason: str | None
    actor_id: int
    actor_login: str
    created_at: datetime


class ReportStockMovementListResponse(BaseModel):
    timezone: str
    items: list[ReportStockMovementItem]
    total: int
    limit: int
    offset: int


@dashboard_router.get("", response_model=DashboardResponse)
def get_dashboard_route(
    _: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> DashboardResponse:
    summary = get_dashboard_summary(session)
    return DashboardResponse(
        timezone=summary.timezone,
        business_date=summary.business_date,
        today_completed_sales_count=summary.today_completed_sales_count,
        today_sales_total=format_decimal_4(summary.today_sales_total),
        today_cash_total=format_decimal_4(summary.today_cash_total),
        today_mpesa_total=format_decimal_4(summary.today_mpesa_total),
        approved_products_count=summary.approved_products_count,
        zero_stock_products_count=summary.zero_stock_products_count,
    )


@reports_router.get("/sales", response_model=SalesReportResponse)
def get_sales_report_route(
    from_date: date | None = Query(default=None),
    to_date: date | None = Query(default=None),
    _: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> SalesReportResponse:
    report = get_sales_report(session, from_date=from_date, to_date=to_date)
    return SalesReportResponse(
        timezone=report.timezone,
        from_date=report.from_date,
        to_date=report.to_date,
        completed_sales_count=report.completed_sales_count,
        total_sales_value=format_decimal_4(report.total_sales_value),
        cash_total=format_decimal_4(report.cash_total),
        mpesa_total=format_decimal_4(report.mpesa_total),
        mpesa_note=(
            "Manually recorded M-PESA amounts and references are not automatically verified."
        ),
    )


@reports_router.get("/inventory/balances", response_model=ReportInventoryBalanceListResponse)
def get_inventory_balances_report_route(
    q: str | None = Query(default=None, max_length=120),
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    _: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> ReportInventoryBalanceListResponse:
    rows, total = list_report_inventory_balances(
        session,
        query=q,
        limit=limit,
        offset=offset,
    )
    return ReportInventoryBalanceListResponse(
        items=[
            ReportInventoryBalanceItem(
                product_id=str(product.id),
                internal_reference=product.internal_reference,
                name=product.name,
                manufacturer_part_number=product.manufacturer_part_number,
                unit_of_measure=None,
                selling_price=format_decimal_4(product.selling_price or ZERO_DECIMAL),
                quantity_on_hand=format_decimal_4(
                    balance.quantity_on_hand if balance is not None else ZERO_DECIMAL
                ),
                updated_at=balance.updated_at if balance is not None else None,
            )
            for product, balance in rows
        ],
        total=total,
        limit=limit,
        offset=offset,
    )


@reports_router.get("/inventory/movements", response_model=ReportStockMovementListResponse)
def get_inventory_movements_report_route(
    from_date: date | None = Query(default=None),
    to_date: date | None = Query(default=None),
    q: str | None = Query(default=None, max_length=120),
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    _: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> ReportStockMovementListResponse:
    items, total = list_report_stock_movements(
        session,
        from_date=from_date,
        to_date=to_date,
        query=q,
        limit=limit,
        offset=offset,
    )
    return ReportStockMovementListResponse(
        timezone=BUSINESS_TIMEZONE_NAME,
        items=[
            ReportStockMovementItem(
                id=str(mov.id),
                product_id=str(mov.product_id),
                product_internal_reference=mov.product.internal_reference,
                product_name=mov.product.name,
                movement_type=mov.movement_type,
                quantity_delta=format_decimal_4(mov.quantity_delta),
                source_type=mov.source_type,
                source_id=str(mov.source_id),
                source_reference=mov.source_reference,
                reason=mov.reason,
                actor_id=mov.actor_id,
                actor_login=mov.actor.login_name,
                created_at=mov.created_at,
            )
            for mov in items
        ],
        total=total,
        limit=limit,
        offset=offset,
    )
