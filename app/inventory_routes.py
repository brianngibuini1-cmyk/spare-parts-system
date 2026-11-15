"""FastAPI routes for suppliers, goods receiving, inventory balances, and stock ledger."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.orm import Session

from app.auth import AuthContext, get_current_auth, require_csrf, require_owner
from app.database import get_session
from app.inventory_service import (
    ZERO_DECIMAL,
    ReceiptLineInput,
    create_goods_receipt,
    create_stock_adjustment,
    create_supplier,
    format_decimal_4,
    get_goods_receipt,
    get_product_inventory_movements,
    get_supplier,
    list_goods_receipts,
    list_inventory_balances,
    list_suppliers,
    set_supplier_active,
    update_supplier,
)
from app.models import GoodsReceipt, InventoryBalance, Product, StockMovement, Supplier, UserAccount

suppliers_router = APIRouter(prefix="/api/v1/suppliers", tags=["suppliers"])
inventory_router = APIRouter(prefix="/api/v1/inventory", tags=["inventory"])


class StrictInput(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class SupplierCreateRequest(StrictInput):
    name: str = Field(min_length=1, max_length=200)
    contact_person: str | None = Field(default=None, max_length=160)
    phone: str | None = Field(default=None, max_length=64)
    email: str | None = Field(default=None, max_length=254)
    notes: str | None = Field(default=None, max_length=2000)


class SupplierUpdateRequest(StrictInput):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    contact_person: str | None = Field(default=None, max_length=160)
    phone: str | None = Field(default=None, max_length=64)
    email: str | None = Field(default=None, max_length=254)
    notes: str | None = Field(default=None, max_length=2000)


class SupplierResponse(BaseModel):
    id: str
    name: str
    contact_person: str | None
    phone: str | None
    email: str | None
    notes: str | None
    is_active: bool
    created_at: datetime
    updated_at: datetime


class SupplierListResponse(BaseModel):
    items: list[SupplierResponse]
    total: int
    limit: int
    offset: int


class GoodsReceiptLineRequest(StrictInput):
    product_id: UUID
    quantity: Decimal
    unit_cost: Decimal = Decimal("0")


class GoodsReceiptCreateRequest(StrictInput):
    idempotency_key: str = Field(min_length=1, max_length=128)
    supplier_id: UUID | None = None
    unlisted_supplier_name: str | None = Field(default=None, max_length=200)
    delivery_note_reference: str | None = Field(default=None, max_length=120)
    notes: str | None = Field(default=None, max_length=2000)
    lines: list[GoodsReceiptLineRequest] = Field(min_length=1, max_length=100)


class GoodsReceiptLineResponse(BaseModel):
    id: str
    line_number: int
    product_id: str
    product_name: str
    internal_reference: str
    manufacturer_part_number: str | None
    quantity: str
    unit_cost: str


class GoodsReceiptResponse(BaseModel):
    id: str
    supplier_id: str | None
    supplier_name: str | None
    unlisted_supplier_name: str | None
    delivery_note_reference: str | None
    notes: str | None
    idempotency_key: str
    received_by: int
    received_by_login: str
    received_at: datetime
    replayed: bool = False
    lines: list[GoodsReceiptLineResponse]


class GoodsReceiptListResponse(BaseModel):
    items: list[GoodsReceiptResponse]
    total: int
    limit: int
    offset: int


class StockAdjustmentCreateRequest(StrictInput):
    product_id: UUID
    quantity_delta: Decimal
    reason: str = Field(min_length=1, max_length=1000)


class StockMovementResponse(BaseModel):
    id: str
    product_id: str
    movement_type: str
    quantity_delta: str
    source_type: str
    source_id: str
    source_reference: str | None
    supplier_name: str | None
    reason: str | None
    actor_id: int
    actor_login: str
    created_at: datetime


class StockAdjustmentResponse(BaseModel):
    movement: StockMovementResponse
    product_id: str
    quantity_on_hand: str


class InventoryBalanceResponse(BaseModel):
    product_id: str
    internal_reference: str
    name: str
    manufacturer_part_number: str | None
    selling_price: str
    quantity_on_hand: str
    updated_at: datetime | None


class InventoryBalanceListResponse(BaseModel):
    items: list[InventoryBalanceResponse]
    total: int
    limit: int
    offset: int


class ProductMovementsResponse(BaseModel):
    product_id: str
    internal_reference: str
    name: str
    manufacturer_part_number: str | None
    quantity_on_hand: str
    items: list[StockMovementResponse]
    total: int
    limit: int
    offset: int


def _to_supplier_response(supplier: Supplier) -> SupplierResponse:
    return SupplierResponse(
        id=str(supplier.id),
        name=supplier.name,
        contact_person=supplier.contact_person,
        phone=supplier.phone,
        email=supplier.email,
        notes=supplier.notes,
        is_active=supplier.is_active,
        created_at=supplier.created_at,
        updated_at=supplier.updated_at,
    )


def _to_receipt_response(receipt: GoodsReceipt, *, replayed: bool = False) -> GoodsReceiptResponse:
    return GoodsReceiptResponse(
        id=str(receipt.id),
        supplier_id=str(receipt.supplier_id) if receipt.supplier_id is not None else None,
        supplier_name=receipt.supplier.name if receipt.supplier is not None else None,
        unlisted_supplier_name=receipt.unlisted_supplier_name,
        delivery_note_reference=receipt.delivery_note_reference,
        notes=receipt.notes,
        idempotency_key=receipt.idempotency_key,
        received_by=receipt.received_by,
        received_by_login=receipt.receiver.login_name,
        received_at=receipt.received_at,
        replayed=replayed,
        lines=[
            GoodsReceiptLineResponse(
                id=str(line.id),
                line_number=line.line_number,
                product_id=str(line.product_id),
                product_name=line.product.name,
                internal_reference=line.product.internal_reference,
                manufacturer_part_number=line.product.manufacturer_part_number,
                quantity=format_decimal_4(line.quantity),
                unit_cost=format_decimal_4(line.unit_cost),
            )
            for line in receipt.lines
        ],
    )


def _to_movement_response(
    movement: StockMovement,
    actor: UserAccount,
    receipt: GoodsReceipt | None = None,
) -> StockMovementResponse:
    supplier_name: str | None = None
    if receipt is not None:
        if receipt.supplier is not None:
            supplier_name = receipt.supplier.name
        else:
            supplier_name = receipt.unlisted_supplier_name
    return StockMovementResponse(
        id=str(movement.id),
        product_id=str(movement.product_id),
        movement_type=movement.movement_type,
        quantity_delta=format_decimal_4(movement.quantity_delta),
        source_type=movement.source_type,
        source_id=str(movement.source_id),
        source_reference=movement.source_reference,
        supplier_name=supplier_name,
        reason=movement.reason,
        actor_id=movement.actor_id,
        actor_login=actor.login_name,
        created_at=movement.created_at,
    )


def _to_balance_response(product: Product, balance: InventoryBalance | None) -> InventoryBalanceResponse:
    qty = balance.quantity_on_hand if balance is not None else ZERO_DECIMAL
    return InventoryBalanceResponse(
        product_id=str(product.id),
        internal_reference=product.internal_reference,
        name=product.name,
        manufacturer_part_number=product.manufacturer_part_number,
        selling_price=format_decimal_4(product.selling_price),
        quantity_on_hand=format_decimal_4(qty),
        updated_at=balance.updated_at if balance is not None else None,
    )


@suppliers_router.get("", response_model=SupplierListResponse)
def list_suppliers_route(
    q: str | None = Query(default=None, max_length=120),
    include_inactive: bool = Query(default=True),
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    auth: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> SupplierListResponse:
    effective_include_inactive = include_inactive if auth.user.role == "owner" else False
    items, total = list_suppliers(
        session,
        query=q,
        include_inactive=effective_include_inactive,
        limit=limit,
        offset=offset,
    )
    return SupplierListResponse(
        items=[_to_supplier_response(s) for s in items],
        total=total,
        limit=limit,
        offset=offset,
    )


@suppliers_router.post("", response_model=SupplierResponse, status_code=status.HTTP_201_CREATED)
def create_supplier_route(
    payload: SupplierCreateRequest,
    request: Request,
    auth: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> SupplierResponse:
    require_csrf(request, auth)
    supplier = create_supplier(
        session,
        name=payload.name,
        contact_person=payload.contact_person,
        phone=payload.phone,
        email=payload.email,
        notes=payload.notes,
    )
    return _to_supplier_response(supplier)


@suppliers_router.get("/{supplier_id}", response_model=SupplierResponse)
def get_supplier_route(
    supplier_id: UUID,
    _: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> SupplierResponse:
    return _to_supplier_response(get_supplier(session, supplier_id))


@suppliers_router.patch("/{supplier_id}", response_model=SupplierResponse)
def update_supplier_route(
    supplier_id: UUID,
    payload: SupplierUpdateRequest,
    request: Request,
    auth: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> SupplierResponse:
    require_csrf(request, auth)
    supplier = update_supplier(
        session,
        supplier_id,
        name=payload.name,
        contact_person=payload.contact_person,
        phone=payload.phone,
        email=payload.email,
        notes=payload.notes,
        fields_set=set(payload.model_fields_set),
    )
    return _to_supplier_response(supplier)


@suppliers_router.post("/{supplier_id}/activate", response_model=SupplierResponse)
def activate_supplier_route(
    supplier_id: UUID,
    request: Request,
    auth: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> SupplierResponse:
    require_csrf(request, auth)
    return _to_supplier_response(set_supplier_active(session, supplier_id, is_active=True))


@suppliers_router.post("/{supplier_id}/deactivate", response_model=SupplierResponse)
def deactivate_supplier_route(
    supplier_id: UUID,
    request: Request,
    auth: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> SupplierResponse:
    require_csrf(request, auth)
    return _to_supplier_response(set_supplier_active(session, supplier_id, is_active=False))


@inventory_router.get("/balances", response_model=InventoryBalanceListResponse)
def list_inventory_balances_route(
    q: str | None = Query(default=None, max_length=120),
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    _: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> InventoryBalanceListResponse:
    rows, total = list_inventory_balances(session, query=q, limit=limit, offset=offset)
    return InventoryBalanceListResponse(
        items=[_to_balance_response(product, balance) for product, balance in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@inventory_router.get("/products/{product_id}/movements", response_model=ProductMovementsResponse)
def get_product_movements_route(
    product_id: UUID,
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    _: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> ProductMovementsResponse:
    product, qty_on_hand, rows, total = get_product_inventory_movements(
        session,
        product_id,
        limit=limit,
        offset=offset,
    )
    return ProductMovementsResponse(
        product_id=str(product.id),
        internal_reference=product.internal_reference,
        name=product.name,
        manufacturer_part_number=product.manufacturer_part_number,
        quantity_on_hand=format_decimal_4(qty_on_hand),
        items=[_to_movement_response(movement, actor, receipt) for movement, actor, receipt in rows],
        total=total,
        limit=limit,
        offset=offset,
    )


@inventory_router.post("/receipts", response_model=GoodsReceiptResponse, status_code=status.HTTP_201_CREATED)
def create_goods_receipt_route(
    payload: GoodsReceiptCreateRequest,
    request: Request,
    response: Response,
    auth: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> GoodsReceiptResponse:
    require_csrf(request, auth)
    result = create_goods_receipt(
        session,
        actor_id=auth.user.id,
        idempotency_key=payload.idempotency_key,
        supplier_id=payload.supplier_id,
        unlisted_supplier_name=payload.unlisted_supplier_name,
        delivery_note_reference=payload.delivery_note_reference,
        notes=payload.notes,
        lines=[
            ReceiptLineInput(
                product_id=line.product_id,
                quantity=line.quantity,
                unit_cost=line.unit_cost,
            )
            for line in payload.lines
        ],
    )
    if result.replayed:
        response.status_code = status.HTTP_200_OK
    return _to_receipt_response(result.receipt, replayed=result.replayed)


@inventory_router.get("/receipts", response_model=GoodsReceiptListResponse)
def list_goods_receipts_route(
    supplier_id: UUID | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    _: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> GoodsReceiptListResponse:
    items, total = list_goods_receipts(session, supplier_id=supplier_id, limit=limit, offset=offset)
    return GoodsReceiptListResponse(
        items=[_to_receipt_response(receipt) for receipt in items],
        total=total,
        limit=limit,
        offset=offset,
    )


@inventory_router.get("/receipts/{receipt_id}", response_model=GoodsReceiptResponse)
def get_goods_receipt_route(
    receipt_id: UUID,
    _: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> GoodsReceiptResponse:
    return _to_receipt_response(get_goods_receipt(session, receipt_id))


@inventory_router.post("/adjustments", response_model=StockAdjustmentResponse, status_code=status.HTTP_201_CREATED)
def create_stock_adjustment_route(
    payload: StockAdjustmentCreateRequest,
    request: Request,
    auth: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> StockAdjustmentResponse:
    require_csrf(request, auth)
    movement, balance, product, actor = create_stock_adjustment(
        session,
        actor_id=auth.user.id,
        product_id=payload.product_id,
        quantity_delta=payload.quantity_delta,
        reason=payload.reason,
    )
    return StockAdjustmentResponse(
        movement=_to_movement_response(movement, actor),
        product_id=str(product.id),
        quantity_on_hand=format_decimal_4(balance.quantity_on_hand),
    )
