"""Transactional business logic for suppliers, goods receiving, and stock ledger."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
import hashlib
import json
from uuid import UUID, uuid4

from fastapi import HTTPException, status
from sqlalchemy import Select, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from app.models import (
    GoodsReceipt,
    GoodsReceiptLine,
    InventoryBalance,
    Product,
    StockMovement,
    Supplier,
    UserAccount,
    utc_now,
)

MAX_DECIMAL_18_4 = Decimal("99999999999999.9999")
ZERO_DECIMAL = Decimal("0.0000")


def normalize_supplier_name(name: str) -> str:
    """Normalize supplier name for case- and whitespace-insensitive uniqueness."""
    return " ".join(name.split()).casefold()


def clean_optional_text(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = value.strip()
    return stripped or None


def quantize_decimal_4(value: Decimal | int | float | str, *, field_name: str) -> Decimal:
    try:
        dec = value if isinstance(value, Decimal) else Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field_name} must be a valid decimal number.",
        ) from exc
    if not dec.is_finite():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field_name} must be finite.",
        )
    if abs(dec) > MAX_DECIMAL_18_4:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field_name} exceeds supported numeric range.",
        )
    try:
        quantized = dec.quantize(Decimal("0.0001"))
    except InvalidOperation as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field_name} must have at most 4 decimal places.",
        ) from exc
    if quantized != dec:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{field_name} must have at most 4 decimal places.",
        )
    return quantized


def format_decimal_4(value: Decimal) -> str:
    return f"{value.quantize(Decimal('0.0001')):.4f}"


@dataclass(frozen=True)
class ReceiptLineInput:
    product_id: UUID
    quantity: Decimal
    unit_cost: Decimal


@dataclass(frozen=True)
class ReceiptCreationResult:
    receipt: GoodsReceipt
    replayed: bool


def _compute_receipt_hash(
    *,
    supplier_id: UUID | None,
    unlisted_supplier_name: str | None,
    delivery_note_reference: str | None,
    notes: str | None,
    lines: list[ReceiptLineInput],
) -> str:
    canonical = {
        "supplier_id": str(supplier_id) if supplier_id is not None else None,
        "unlisted_supplier_name": unlisted_supplier_name,
        "delivery_note_reference": delivery_note_reference,
        "notes": notes,
        "lines": [
            {
                "product_id": str(line.product_id),
                "quantity": format_decimal_4(line.quantity),
                "unit_cost": format_decimal_4(line.unit_cost),
            }
            for line in lines
        ],
    }
    encoded = json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def create_supplier(
    session: Session,
    *,
    name: str,
    contact_person: str | None = None,
    phone: str | None = None,
    email: str | None = None,
    notes: str | None = None,
) -> Supplier:
    trimmed_name = name.strip()
    if not trimmed_name:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Supplier name cannot be blank.",
        )
    normalized = normalize_supplier_name(trimmed_name)
    existing = session.scalar(select(Supplier).where(Supplier.normalized_name == normalized))
    if existing is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A supplier with this name already exists.",
        )
    now = utc_now()
    supplier = Supplier(
        name=trimmed_name,
        normalized_name=normalized,
        contact_person=clean_optional_text(contact_person),
        phone=clean_optional_text(phone),
        email=clean_optional_text(email),
        notes=clean_optional_text(notes),
        is_active=True,
        created_at=now,
        updated_at=now,
    )
    session.add(supplier)
    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A supplier with this name already exists.",
        ) from exc
    session.refresh(supplier)
    return supplier


def list_suppliers(
    session: Session,
    *,
    query: str | None = None,
    include_inactive: bool = True,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[Supplier], int]:
    stmt: Select[tuple[Supplier]] = select(Supplier)
    count_stmt = select(func.count()).select_from(Supplier)

    if not include_inactive:
        stmt = stmt.where(Supplier.is_active.is_(True))
        count_stmt = count_stmt.where(Supplier.is_active.is_(True))

    cleaned_query = clean_optional_text(query)
    if cleaned_query:
        pattern = f"%{cleaned_query}%"
        filter_expr = or_(
            Supplier.name.ilike(pattern),
            Supplier.contact_person.ilike(pattern),
            Supplier.phone.ilike(pattern),
            Supplier.email.ilike(pattern),
        )
        stmt = stmt.where(filter_expr)
        count_stmt = count_stmt.where(filter_expr)

    total = int(session.scalar(count_stmt) or 0)
    items = list(
        session.scalars(
            stmt.order_by(Supplier.is_active.desc(), Supplier.name.asc(), Supplier.id.asc())
            .offset(offset)
            .limit(limit)
        ).all()
    )
    return items, total


def get_supplier(session: Session, supplier_id: UUID) -> Supplier:
    supplier = session.get(Supplier, supplier_id)
    if supplier is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Supplier not found.")
    return supplier


def update_supplier(
    session: Session,
    supplier_id: UUID,
    *,
    name: str | None = None,
    contact_person: str | None = None,
    phone: str | None = None,
    email: str | None = None,
    notes: str | None = None,
    fields_set: set[str],
) -> Supplier:
    supplier = get_supplier(session, supplier_id)
    if "name" in fields_set:
        if name is None or not name.strip():
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Supplier name cannot be blank.",
            )
        trimmed_name = name.strip()
        normalized = normalize_supplier_name(trimmed_name)
        duplicate = session.scalar(
            select(Supplier).where(Supplier.normalized_name == normalized, Supplier.id != supplier_id)
        )
        if duplicate is not None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="A supplier with this name already exists.",
            )
        supplier.name = trimmed_name
        supplier.normalized_name = normalized

    if "contact_person" in fields_set:
        supplier.contact_person = clean_optional_text(contact_person)
    if "phone" in fields_set:
        supplier.phone = clean_optional_text(phone)
    if "email" in fields_set:
        supplier.email = clean_optional_text(email)
    if "notes" in fields_set:
        supplier.notes = clean_optional_text(notes)

    supplier.updated_at = utc_now()
    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A supplier with this name already exists.",
        ) from exc
    session.refresh(supplier)
    return supplier


def set_supplier_active(session: Session, supplier_id: UUID, *, is_active: bool) -> Supplier:
    supplier = get_supplier(session, supplier_id)
    if supplier.is_active != is_active:
        supplier.is_active = is_active
        supplier.updated_at = utc_now()
        session.commit()
        session.refresh(supplier)
    return supplier


def _load_receipt_with_relations(session: Session, receipt_id: UUID) -> GoodsReceipt:
    receipt = session.scalar(
        select(GoodsReceipt)
        .options(
            selectinload(GoodsReceipt.supplier),
            selectinload(GoodsReceipt.receiver),
            selectinload(GoodsReceipt.lines).selectinload(GoodsReceiptLine.product),
        )
        .where(GoodsReceipt.id == receipt_id)
    )
    if receipt is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Goods receipt not found.")
    return receipt


def create_goods_receipt(
    session: Session,
    *,
    actor_id: int,
    idempotency_key: str,
    supplier_id: UUID | None,
    unlisted_supplier_name: str | None,
    delivery_note_reference: str | None,
    notes: str | None,
    lines: list[ReceiptLineInput],
) -> ReceiptCreationResult:
    cleaned_key = idempotency_key.strip()
    if not cleaned_key or len(cleaned_key) > 128:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="idempotency_key must be between 1 and 128 characters.",
        )
    if not lines:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="At least one receipt line is required.",
        )

    cleaned_unlisted = clean_optional_text(unlisted_supplier_name)
    cleaned_delivery_ref = clean_optional_text(delivery_note_reference)
    cleaned_notes = clean_optional_text(notes)

    if supplier_id is not None and cleaned_unlisted is not None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Specify either supplier_id or unlisted_supplier_name, not both.",
        )

    normalized_lines: list[ReceiptLineInput] = []
    for line in lines:
        qty = quantize_decimal_4(line.quantity, field_name="quantity")
        cost = quantize_decimal_4(line.unit_cost, field_name="unit_cost")
        if qty <= ZERO_DECIMAL:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Receipt line quantity must be greater than zero.",
            )
        if cost < ZERO_DECIMAL:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Receipt line unit_cost cannot be negative.",
            )
        normalized_lines.append(
            ReceiptLineInput(product_id=line.product_id, quantity=qty, unit_cost=cost)
        )

    request_hash = _compute_receipt_hash(
        supplier_id=supplier_id,
        unlisted_supplier_name=cleaned_unlisted,
        delivery_note_reference=cleaned_delivery_ref,
        notes=cleaned_notes,
        lines=normalized_lines,
    )

    existing = session.scalar(select(GoodsReceipt).where(GoodsReceipt.idempotency_key == cleaned_key))
    if existing is not None:
        if existing.request_hash != request_hash:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Idempotency key was already used with a different receipt payload.",
            )
        return ReceiptCreationResult(
            receipt=_load_receipt_with_relations(session, existing.id),
            replayed=True,
        )

    if supplier_id is not None:
        supplier = session.get(Supplier, supplier_id)
        if supplier is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Supplier not found.")
        if not supplier.is_active:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Inactive suppliers cannot be selected for new goods receipts.",
            )

    # Lock products and balances in deterministic UUID order to avoid deadlocks.
    unique_product_ids = sorted({line.product_id for line in normalized_lines})
    locked_products = {
        product.id: product
        for product in session.scalars(
            select(Product)
            .where(Product.id.in_(unique_product_ids))
            .order_by(Product.id.asc())
            .with_for_update()
        ).all()
    }
    if len(locked_products) != len(unique_product_ids):
        missing = [str(pid) for pid in unique_product_ids if pid not in locked_products]
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Product not found: {', '.join(missing)}",
        )

    for pid in unique_product_ids:
        product = locked_products[pid]
        if product.approval_status != "approved":
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Only approved products can be received into stock ({product.name}).",
            )

    locked_balances = {
        balance.product_id: balance
        for balance in session.scalars(
            select(InventoryBalance)
            .where(InventoryBalance.product_id.in_(unique_product_ids))
            .order_by(InventoryBalance.product_id.asc())
            .with_for_update()
        ).all()
    }

    now = utc_now()
    receipt_id = uuid4()
    source_ref = cleaned_delivery_ref or f"RCP-{str(receipt_id)[:8].upper()}"

    receipt = GoodsReceipt(
        id=receipt_id,
        supplier_id=supplier_id,
        unlisted_supplier_name=cleaned_unlisted,
        delivery_note_reference=cleaned_delivery_ref,
        notes=cleaned_notes,
        idempotency_key=cleaned_key,
        request_hash=request_hash,
        received_by=actor_id,
        received_at=now,
        created_at=now,
    )
    session.add(receipt)

    for idx, line in enumerate(normalized_lines, start=1):
        session.add(
            GoodsReceiptLine(
                id=uuid4(),
                receipt_id=receipt_id,
                line_number=idx,
                product_id=line.product_id,
                quantity=line.quantity,
                unit_cost=line.unit_cost,
            )
        )
        session.add(
            StockMovement(
                id=uuid4(),
                product_id=line.product_id,
                movement_type="receipt",
                quantity_delta=line.quantity,
                source_type="goods_receipt",
                source_id=receipt_id,
                source_reference=source_ref,
                reason=cleaned_notes,
                actor_id=actor_id,
                created_at=now,
            )
        )
        balance = locked_balances.get(line.product_id)
        if balance is None:
            balance = InventoryBalance(
                product_id=line.product_id,
                quantity_on_hand=line.quantity,
                updated_at=now,
            )
            session.add(balance)
            locked_balances[line.product_id] = balance
        else:
            new_qty = (balance.quantity_on_hand + line.quantity).quantize(Decimal("0.0001"))
            if new_qty > MAX_DECIMAL_18_4:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail="Resulting stock balance exceeds supported numeric range.",
                )
            balance.quantity_on_hand = new_qty
            balance.updated_at = now

    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        race_existing = session.scalar(select(GoodsReceipt).where(GoodsReceipt.idempotency_key == cleaned_key))
        if race_existing is not None:
            if race_existing.request_hash != request_hash:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Idempotency key was already used with a different receipt payload.",
                ) from exc
            return ReceiptCreationResult(
                receipt=_load_receipt_with_relations(session, race_existing.id),
                replayed=True,
            )
        raise

    return ReceiptCreationResult(
        receipt=_load_receipt_with_relations(session, receipt_id),
        replayed=False,
    )


def create_stock_adjustment(
    session: Session,
    *,
    actor_id: int,
    product_id: UUID,
    quantity_delta: Decimal,
    reason: str,
) -> tuple[StockMovement, InventoryBalance, Product, UserAccount]:
    delta = quantize_decimal_4(quantity_delta, field_name="quantity_delta")
    if delta == ZERO_DECIMAL:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Adjustment quantity_delta must be non-zero.",
        )
    cleaned_reason = reason.strip()
    if not cleaned_reason:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Adjustment reason is required.",
        )

    product = session.scalar(select(Product).where(Product.id == product_id).with_for_update())
    if product is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Product not found.")
    if product.approval_status != "approved":
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Only approved products can have stock adjustments.",
        )

    balance = session.scalar(
        select(InventoryBalance).where(InventoryBalance.product_id == product_id).with_for_update()
    )
    current_qty = balance.quantity_on_hand if balance is not None else ZERO_DECIMAL
    new_qty = (current_qty + delta).quantize(Decimal("0.0001"))
    if new_qty < ZERO_DECIMAL:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Insufficient stock for {product.name}. Current balance is {format_decimal_4(current_qty)}.",
        )
    if new_qty > MAX_DECIMAL_18_4:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Resulting stock balance exceeds supported numeric range.",
        )

    now = utc_now()
    movement_id = uuid4()
    movement = StockMovement(
        id=movement_id,
        product_id=product_id,
        movement_type="adjustment",
        quantity_delta=delta,
        source_type="stock_adjustment",
        source_id=movement_id,
        source_reference=f"ADJ-{str(movement_id)[:8].upper()}",
        reason=cleaned_reason,
        actor_id=actor_id,
        created_at=now,
    )
    session.add(movement)

    if balance is None:
        balance = InventoryBalance(
            product_id=product_id,
            quantity_on_hand=new_qty,
            updated_at=now,
        )
        session.add(balance)
    else:
        balance.quantity_on_hand = new_qty
        balance.updated_at = now

    session.commit()
    session.refresh(movement)
    session.refresh(balance)
    actor = session.get(UserAccount, actor_id)
    assert actor is not None
    return movement, balance, product, actor


def list_inventory_balances(
    session: Session,
    *,
    query: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[tuple[Product, InventoryBalance | None]], int]:
    base_filter = [Product.approval_status == "approved"]
    cleaned_query = clean_optional_text(query)
    if cleaned_query:
        pattern = f"%{cleaned_query}%"
        base_filter.append(
            or_(
                Product.name.ilike(pattern),
                Product.manufacturer_part_number.ilike(pattern),
                Product.internal_reference.ilike(pattern),
            )
        )

    count_stmt = select(func.count()).select_from(Product).where(*base_filter)
    total = int(session.scalar(count_stmt) or 0)

    rows = list(
        session.execute(
            select(Product, InventoryBalance)
            .outerjoin(InventoryBalance, InventoryBalance.product_id == Product.id)
            .where(*base_filter)
            .order_by(Product.name.asc(), Product.id.asc())
            .offset(offset)
            .limit(limit)
        ).all()
    )
    return [(row[0], row[1]) for row in rows], total


def get_product_inventory_movements(
    session: Session,
    product_id: UUID,
    *,
    limit: int = 50,
    offset: int = 0,
) -> tuple[Product, Decimal, list[tuple[StockMovement, UserAccount, GoodsReceipt | None]], int]:
    product = session.get(Product, product_id)
    if product is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Product not found.")

    balance = session.get(InventoryBalance, product_id)
    qty_on_hand = balance.quantity_on_hand if balance is not None else ZERO_DECIMAL

    total = int(
        session.scalar(
            select(func.count()).select_from(StockMovement).where(StockMovement.product_id == product_id)
        )
        or 0
    )

    movements = list(
        session.scalars(
            select(StockMovement)
            .options(selectinload(StockMovement.actor))
            .where(StockMovement.product_id == product_id)
            .order_by(StockMovement.created_at.desc(), StockMovement.id.desc())
            .offset(offset)
            .limit(limit)
        ).all()
    )

    receipt_ids = {m.source_id for m in movements if m.source_type == "goods_receipt"}
    receipts_by_id: dict[UUID, GoodsReceipt] = {}
    if receipt_ids:
        receipts = session.scalars(
            select(GoodsReceipt)
            .options(selectinload(GoodsReceipt.supplier))
            .where(GoodsReceipt.id.in_(receipt_ids))
        ).all()
        receipts_by_id = {r.id: r for r in receipts}

    enriched = [
        (
            m,
            m.actor,
            receipts_by_id.get(m.source_id) if m.source_type == "goods_receipt" else None,
        )
        for m in movements
    ]
    return product, qty_on_hand, enriched, total


def list_goods_receipts(
    session: Session,
    *,
    supplier_id: UUID | None = None,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[GoodsReceipt], int]:
    stmt = select(GoodsReceipt).options(
        selectinload(GoodsReceipt.supplier),
        selectinload(GoodsReceipt.receiver),
        selectinload(GoodsReceipt.lines).selectinload(GoodsReceiptLine.product),
    )
    count_stmt = select(func.count()).select_from(GoodsReceipt)
    if supplier_id is not None:
        stmt = stmt.where(GoodsReceipt.supplier_id == supplier_id)
        count_stmt = count_stmt.where(GoodsReceipt.supplier_id == supplier_id)

    total = int(session.scalar(count_stmt) or 0)
    items = list(
        session.scalars(
            stmt.order_by(GoodsReceipt.received_at.desc(), GoodsReceipt.id.desc())
            .offset(offset)
            .limit(limit)
        ).all()
    )
    return items, total


def get_goods_receipt(session: Session, receipt_id: UUID) -> GoodsReceipt:
    return _load_receipt_with_relations(session, receipt_id)
