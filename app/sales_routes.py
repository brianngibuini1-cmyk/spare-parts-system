"""FastAPI routes for sales checkout, payments, and digital receipts."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.orm import Session

from app.auth import AuthContext, get_current_auth, require_csrf
from app.database import get_session
from app.inventory_service import format_decimal_4
from app.models import Sale
from app.sales_service import SaleLineInput, create_sale, get_sale, list_sales

sales_router = APIRouter(prefix="/api/v1/sales", tags=["sales"])


class StrictInput(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class SaleLineRequest(StrictInput):
    product_id: UUID
    quantity: Decimal


class SaleCreateRequest(StrictInput):
    idempotency_key: str = Field(min_length=1, max_length=128)
    payment_method: str = Field(default="cash", min_length=1, max_length=32)
    amount_tendered: Decimal
    payment_reference: str | None = Field(default=None, max_length=120)
    notes: str | None = Field(default=None, max_length=2000)
    lines: list[SaleLineRequest] = Field(min_length=1, max_length=100)


class SaleLineResponse(BaseModel):
    id: str
    line_number: int
    product_id: str
    product_internal_reference: str
    product_name: str
    product_description: str | None
    manufacturer_part_number: str | None
    unit_price: str
    quantity: str
    line_total: str


class SaleResponse(BaseModel):
    id: str
    receipt_number: str
    idempotency_key: str
    status: str
    total_amount: str
    payment_method: str
    amount_tendered: str
    change_given: str
    payment_reference: str | None
    notes: str | None
    sold_by: int
    sold_by_login: str
    sold_at: datetime
    replayed: bool = False
    lines: list[SaleLineResponse]


class SaleListResponse(BaseModel):
    items: list[SaleResponse]
    total: int
    limit: int
    offset: int


def _to_sale_response(sale: Sale, *, replayed: bool = False) -> SaleResponse:
    return SaleResponse(
        id=str(sale.id),
        receipt_number=sale.receipt_number,
        idempotency_key=sale.idempotency_key,
        status=sale.status,
        total_amount=format_decimal_4(sale.total_amount),
        payment_method=sale.payment_method,
        amount_tendered=format_decimal_4(sale.amount_tendered),
        change_given=format_decimal_4(sale.change_given),
        payment_reference=sale.payment_reference,
        notes=sale.notes,
        sold_by=sale.sold_by,
        sold_by_login=sale.seller.login_name,
        sold_at=sale.sold_at,
        replayed=replayed,
        lines=[
            SaleLineResponse(
                id=str(line.id),
                line_number=line.line_number,
                product_id=str(line.product_id),
                product_internal_reference=line.product_internal_reference,
                product_name=line.product_name,
                product_description=line.product_description,
                manufacturer_part_number=line.manufacturer_part_number,
                unit_price=format_decimal_4(line.unit_price),
                quantity=format_decimal_4(line.quantity),
                line_total=format_decimal_4(line.line_total),
            )
            for line in sale.lines
        ],
    )


@sales_router.post("", response_model=SaleResponse, status_code=status.HTTP_201_CREATED)
def create_sale_route(
    payload: SaleCreateRequest,
    request: Request,
    response: Response,
    auth: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> SaleResponse:
    require_csrf(request, auth)
    result = create_sale(
        session,
        actor_id=auth.user.id,
        idempotency_key=payload.idempotency_key,
        payment_method=payload.payment_method,
        amount_tendered=payload.amount_tendered,
        payment_reference=payload.payment_reference,
        notes=payload.notes,
        lines=[
            SaleLineInput(product_id=line.product_id, quantity=line.quantity)
            for line in payload.lines
        ],
    )
    if result.replayed:
        response.status_code = status.HTTP_200_OK
    return _to_sale_response(result.sale, replayed=result.replayed)


@sales_router.get("", response_model=SaleListResponse)
def list_sales_route(
    q: str | None = Query(default=None, max_length=120),
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    _: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> SaleListResponse:
    items, total = list_sales(session, query=q, limit=limit, offset=offset)
    return SaleListResponse(
        items=[_to_sale_response(sale) for sale in items],
        total=total,
        limit=limit,
        offset=offset,
    )


@sales_router.get("/{sale_id}", response_model=SaleResponse)
def get_sale_route(
    sale_id: UUID,
    _: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> SaleResponse:
    return _to_sale_response(get_sale(session, sale_id))
