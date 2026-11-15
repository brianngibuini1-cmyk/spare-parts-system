"""Read-only aggregation queries for operational dashboard and basic reports."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
from zoneinfo import ZoneInfo

from fastapi import HTTPException, status
from sqlalchemy import case, func, or_, select
from sqlalchemy.orm import Session, selectinload

from app.inventory_service import ZERO_DECIMAL, clean_optional_text
from app.models import InventoryBalance, Product, Sale, StockMovement

BUSINESS_TIMEZONE_NAME = "Africa/Nairobi"
BUSINESS_TZ = ZoneInfo(BUSINESS_TIMEZONE_NAME)


@dataclass(frozen=True)
class DashboardSummary:
    timezone: str
    business_date: date
    today_completed_sales_count: int
    today_sales_total: Decimal
    today_cash_total: Decimal
    today_mpesa_total: Decimal
    approved_products_count: int
    zero_stock_products_count: int


@dataclass(frozen=True)
class SalesReportSummary:
    timezone: str
    from_date: date
    to_date: date
    completed_sales_count: int
    total_sales_value: Decimal
    cash_total: Decimal
    mpesa_total: Decimal


def current_business_date(now: datetime | None = None) -> date:
    current = now if now is not None else datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    return current.astimezone(BUSINESS_TZ).date()


def nairobi_date_range_utc(from_date: date, to_date: date) -> tuple[datetime, datetime]:
    if from_date > to_date:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Start date cannot be after end date.",
        )
    start_local = datetime.combine(from_date, time.min, tzinfo=BUSINESS_TZ)
    end_local = datetime.combine(to_date + timedelta(days=1), time.min, tzinfo=BUSINESS_TZ)
    return start_local.astimezone(timezone.utc), end_local.astimezone(timezone.utc)


def resolve_report_dates(
    from_date: date | None,
    to_date: date | None,
    *,
    now: datetime | None = None,
) -> tuple[date, date]:
    today = current_business_date(now)
    resolved_to = to_date or today
    resolved_from = from_date or resolved_to
    if resolved_from > resolved_to:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Start date cannot be after end date.",
        )
    return resolved_from, resolved_to


def _aggregate_sales(
    session: Session,
    *,
    start_utc: datetime,
    end_utc: datetime,
) -> tuple[int, Decimal, Decimal, Decimal]:
    stmt = select(
        func.count(Sale.id),
        func.coalesce(func.sum(Sale.total_amount), 0),
        func.coalesce(
            func.sum(case((Sale.payment_method == "cash", Sale.total_amount), else_=0)),
            0,
        ),
        func.coalesce(
            func.sum(case((Sale.payment_method == "mpesa", Sale.total_amount), else_=0)),
            0,
        ),
    ).where(
        Sale.status == "completed",
        Sale.sold_at >= start_utc,
        Sale.sold_at < end_utc,
    )
    count, total_val, cash_val, mpesa_val = session.execute(stmt).one()
    return (
        int(count or 0),
        Decimal(total_val).quantize(Decimal("0.0001")),
        Decimal(cash_val).quantize(Decimal("0.0001")),
        Decimal(mpesa_val).quantize(Decimal("0.0001")),
    )


def get_dashboard_summary(
    session: Session,
    *,
    now: datetime | None = None,
) -> DashboardSummary:
    business_day = current_business_date(now)
    start_utc, end_utc = nairobi_date_range_utc(business_day, business_day)
    sales_count, sales_total, cash_total, mpesa_total = _aggregate_sales(
        session,
        start_utc=start_utc,
        end_utc=end_utc,
    )

    inv_stmt = (
        select(
            func.count(Product.id),
            func.coalesce(
                func.sum(
                    case(
                        (func.coalesce(InventoryBalance.quantity_on_hand, ZERO_DECIMAL) <= 0, 1),
                        else_=0,
                    )
                ),
                0,
            ),
        )
        .select_from(Product)
        .outerjoin(InventoryBalance, InventoryBalance.product_id == Product.id)
        .where(Product.approval_status == "approved")
    )
    approved_count, zero_stock_count = session.execute(inv_stmt).one()

    return DashboardSummary(
        timezone=BUSINESS_TIMEZONE_NAME,
        business_date=business_day,
        today_completed_sales_count=sales_count,
        today_sales_total=sales_total,
        today_cash_total=cash_total,
        today_mpesa_total=mpesa_total,
        approved_products_count=int(approved_count or 0),
        zero_stock_products_count=int(zero_stock_count or 0),
    )


def get_sales_report(
    session: Session,
    *,
    from_date: date | None = None,
    to_date: date | None = None,
    now: datetime | None = None,
) -> SalesReportSummary:
    resolved_from, resolved_to = resolve_report_dates(from_date, to_date, now=now)
    start_utc, end_utc = nairobi_date_range_utc(resolved_from, resolved_to)
    sales_count, total_val, cash_val, mpesa_val = _aggregate_sales(
        session,
        start_utc=start_utc,
        end_utc=end_utc,
    )
    return SalesReportSummary(
        timezone=BUSINESS_TIMEZONE_NAME,
        from_date=resolved_from,
        to_date=resolved_to,
        completed_sales_count=sales_count,
        total_sales_value=total_val,
        cash_total=cash_val,
        mpesa_total=mpesa_val,
    )


def list_report_inventory_balances(
    session: Session,
    *,
    query: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[tuple[Product, InventoryBalance | None]], int]:
    stmt = (
        select(Product, InventoryBalance)
        .outerjoin(InventoryBalance, InventoryBalance.product_id == Product.id)
        .where(Product.approval_status == "approved")
    )
    count_stmt = (
        select(func.count())
        .select_from(Product)
        .where(Product.approval_status == "approved")
    )

    cleaned_query = clean_optional_text(query)
    if cleaned_query:
        pattern = f"%{cleaned_query}%"
        filter_expr = or_(
            Product.name.ilike(pattern),
            Product.internal_reference.ilike(pattern),
            Product.manufacturer_part_number.ilike(pattern),
        )
        stmt = stmt.where(filter_expr)
        count_stmt = count_stmt.where(filter_expr)

    total = int(session.scalar(count_stmt) or 0)
    rows = list(
        session.execute(
            stmt.order_by(Product.name.asc(), Product.id.asc())
            .offset(offset)
            .limit(limit)
        ).all()
    )
    return [(row[0], row[1]) for row in rows], total


def list_report_stock_movements(
    session: Session,
    *,
    from_date: date | None = None,
    to_date: date | None = None,
    query: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[StockMovement], int]:
    if from_date is not None and to_date is not None and from_date > to_date:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Start date cannot be after end date.",
        )

    stmt = select(StockMovement).options(
        selectinload(StockMovement.product),
        selectinload(StockMovement.actor),
    )
    count_stmt = select(func.count()).select_from(StockMovement)

    if from_date is not None:
        start_utc, _ = nairobi_date_range_utc(from_date, from_date)
        stmt = stmt.where(StockMovement.created_at >= start_utc)
        count_stmt = count_stmt.where(StockMovement.created_at >= start_utc)
    if to_date is not None:
        _, end_utc = nairobi_date_range_utc(to_date, to_date)
        stmt = stmt.where(StockMovement.created_at < end_utc)
        count_stmt = count_stmt.where(StockMovement.created_at < end_utc)

    cleaned_query = clean_optional_text(query)
    if cleaned_query:
        pattern = f"%{cleaned_query}%"
        stmt = stmt.join(Product, Product.id == StockMovement.product_id).where(
            or_(
                Product.name.ilike(pattern),
                Product.internal_reference.ilike(pattern),
                StockMovement.source_reference.ilike(pattern),
            )
        )
        count_stmt = count_stmt.join(Product, Product.id == StockMovement.product_id).where(
            or_(
                Product.name.ilike(pattern),
                Product.internal_reference.ilike(pattern),
                StockMovement.source_reference.ilike(pattern),
            )
        )

    total = int(session.scalar(count_stmt) or 0)
    items = list(
        session.scalars(
            stmt.order_by(StockMovement.created_at.desc(), StockMovement.id.desc())
            .offset(offset)
            .limit(limit)
        ).all()
    )
    return items, total
