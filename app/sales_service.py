"""Transactional business logic for sales, payments, stock deduction, and digital receipts."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
import hashlib
import json
from uuid import UUID, uuid4

from fastapi import HTTPException, status
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from app.inventory_service import (
    MAX_DECIMAL_18_4,
    ZERO_DECIMAL,
    clean_optional_text,
    format_decimal_4,
    quantize_decimal_4,
)
from app.models import (
    InventoryBalance,
    Product,
    Sale,
    SaleLine,
    StockMovement,
    utc_now,
)

ALLOWED_PAYMENT_METHODS = ("cash", "mpesa")


@dataclass(frozen=True)
class SaleLineInput:
    product_id: UUID
    quantity: Decimal


@dataclass(frozen=True)
class SaleCreationResult:
    sale: Sale
    replayed: bool


def _compute_sale_hash(
    *,
    payment_method: str,
    amount_tendered: Decimal,
    payment_reference: str | None,
    notes: str | None,
    lines: list[SaleLineInput],
) -> str:
    canonical = {
        "payment_method": payment_method,
        "amount_tendered": format_decimal_4(amount_tendered),
        "payment_reference": payment_reference,
        "notes": notes,
        "lines": [
            {
                "product_id": str(line.product_id),
                "quantity": format_decimal_4(line.quantity),
            }
            for line in lines
        ],
    }
    encoded = json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _load_sale_with_relations(session: Session, sale_id: UUID) -> Sale:
    sale = session.scalar(
        select(Sale)
        .options(
            selectinload(Sale.seller),
            selectinload(Sale.lines),
        )
        .where(Sale.id == sale_id)
    )
    if sale is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Sale not found.")
    return sale


def create_sale(
    session: Session,
    *,
    actor_id: int,
    idempotency_key: str,
    payment_method: str,
    amount_tendered: Decimal,
    payment_reference: str | None,
    notes: str | None,
    lines: list[SaleLineInput],
) -> SaleCreationResult:
    cleaned_key = idempotency_key.strip()
    if not cleaned_key or len(cleaned_key) > 128:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="idempotency_key must be between 1 and 128 characters.",
        )
    if not lines:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="At least one sale line is required.",
        )

    normalized_method = payment_method.strip().casefold()
    if normalized_method not in ALLOWED_PAYMENT_METHODS:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"payment_method must be one of: {', '.join(ALLOWED_PAYMENT_METHODS)}.",
        )

    tendered = quantize_decimal_4(amount_tendered, field_name="amount_tendered")
    if tendered < ZERO_DECIMAL:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="amount_tendered cannot be negative.",
        )

    cleaned_ref = clean_optional_text(payment_reference)
    cleaned_notes = clean_optional_text(notes)

    seen_products: set[UUID] = set()
    normalized_lines: list[SaleLineInput] = []
    for line in lines:
        if line.product_id in seen_products:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Duplicate product in sale lines; combine quantities into a single line.",
            )
        seen_products.add(line.product_id)
        qty = quantize_decimal_4(line.quantity, field_name="quantity")
        if qty <= ZERO_DECIMAL:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Sale line quantity must be greater than zero.",
            )
        normalized_lines.append(SaleLineInput(product_id=line.product_id, quantity=qty))

    request_hash = _compute_sale_hash(
        payment_method=normalized_method,
        amount_tendered=tendered,
        payment_reference=cleaned_ref,
        notes=cleaned_notes,
        lines=normalized_lines,
    )

    existing = session.scalar(select(Sale).where(Sale.idempotency_key == cleaned_key))
    if existing is not None:
        if existing.request_hash != request_hash:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Idempotency key was already used with a different sale payload.",
            )
        return SaleCreationResult(
            sale=_load_sale_with_relations(session, existing.id),
            replayed=True,
        )

    unique_product_ids = sorted(seen_products)
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

    locked_balances = {
        balance.product_id: balance
        for balance in session.scalars(
            select(InventoryBalance)
            .where(InventoryBalance.product_id.in_(unique_product_ids))
            .order_by(InventoryBalance.product_id.asc())
            .with_for_update()
        ).all()
    }

    total_amount = ZERO_DECIMAL
    computed_lines: list[tuple[SaleLineInput, Product, Decimal, Decimal]] = []
    for line in normalized_lines:
        product = locked_products[line.product_id]
        if product.approval_status != "approved":
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Only approved products can be sold ({product.name}).",
            )
        if product.selling_price is None or product.selling_price < ZERO_DECIMAL:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"Product does not have a valid selling price ({product.name}).",
            )

        unit_price = product.selling_price.quantize(Decimal("0.0001"))
        line_total = (line.quantity * unit_price).quantize(Decimal("0.0001"))
        if line_total > MAX_DECIMAL_18_4:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Line total exceeds supported numeric range.",
            )
        total_amount = (total_amount + line_total).quantize(Decimal("0.0001"))
        if total_amount > MAX_DECIMAL_18_4:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Sale total exceeds supported numeric range.",
            )

        balance = locked_balances.get(line.product_id)
        current_qty = balance.quantity_on_hand if balance is not None else ZERO_DECIMAL
        if current_qty < line.quantity:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=(
                    f"Insufficient stock for {product.name}. "
                    f"Available: {format_decimal_4(current_qty)}, requested: {format_decimal_4(line.quantity)}."
                ),
            )
        computed_lines.append((line, product, unit_price, line_total))

    if tendered < total_amount:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=(
                f"Payment amount ({format_decimal_4(tendered)}) is less than "
                f"sale total ({format_decimal_4(total_amount)})."
            ),
        )
    if normalized_method != "cash" and tendered != total_amount:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=(
                f"Manual M-PESA payment amount ({format_decimal_4(tendered)}) must equal "
                f"sale total ({format_decimal_4(total_amount)})."
            ),
        )
    change_given = (tendered - total_amount).quantize(Decimal("0.0001"))

    now = utc_now()
    sale_id = uuid4()
    receipt_number = f"RCPT-{now.strftime('%Y%m%d')}-{str(sale_id)[:8].upper()}"

    sale = Sale(
        id=sale_id,
        receipt_number=receipt_number,
        idempotency_key=cleaned_key,
        request_hash=request_hash,
        status="completed",
        total_amount=total_amount,
        payment_method=normalized_method,
        amount_tendered=tendered,
        change_given=change_given,
        payment_reference=cleaned_ref,
        notes=cleaned_notes,
        sold_by=actor_id,
        sold_at=now,
        created_at=now,
    )
    session.add(sale)

    for idx, (line, product, unit_price, line_total) in enumerate(computed_lines, start=1):
        session.add(
            SaleLine(
                id=uuid4(),
                sale_id=sale_id,
                line_number=idx,
                product_id=product.id,
                product_internal_reference=product.internal_reference,
                product_name=product.name,
                product_description=product.description,
                manufacturer_part_number=product.manufacturer_part_number,
                unit_price=unit_price,
                quantity=line.quantity,
                line_total=line_total,
            )
        )
        session.add(
            StockMovement(
                id=uuid4(),
                product_id=product.id,
                movement_type="sale",
                quantity_delta=-line.quantity,
                source_type="sale",
                source_id=sale_id,
                source_reference=receipt_number,
                reason=None,
                actor_id=actor_id,
                created_at=now,
            )
        )
        balance = locked_balances[product.id]
        balance.quantity_on_hand = (balance.quantity_on_hand - line.quantity).quantize(Decimal("0.0001"))
        balance.updated_at = now

    try:
        session.commit()
    except IntegrityError as exc:
        session.rollback()
        race_existing = session.scalar(select(Sale).where(Sale.idempotency_key == cleaned_key))
        if race_existing is not None:
            if race_existing.request_hash != request_hash:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="Idempotency key was already used with a different sale payload.",
                ) from exc
            return SaleCreationResult(
                sale=_load_sale_with_relations(session, race_existing.id),
                replayed=True,
            )
        raise

    return SaleCreationResult(
        sale=_load_sale_with_relations(session, sale_id),
        replayed=False,
    )


def list_sales(
    session: Session,
    *,
    query: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[Sale], int]:
    stmt = select(Sale).options(
        selectinload(Sale.seller),
        selectinload(Sale.lines),
    )
    count_stmt = select(func.count()).select_from(Sale)

    cleaned_query = clean_optional_text(query)
    if cleaned_query:
        pattern = f"%{cleaned_query}%"
        filter_expr = or_(
            Sale.receipt_number.ilike(pattern),
            Sale.payment_reference.ilike(pattern),
        )
        stmt = stmt.where(filter_expr)
        count_stmt = count_stmt.where(filter_expr)

    total = int(session.scalar(count_stmt) or 0)
    items = list(
        session.scalars(
            stmt.order_by(Sale.sold_at.desc(), Sale.id.desc())
            .offset(offset)
            .limit(limit)
        ).all()
    )
    return items, total


def get_sale(session: Session, sale_id: UUID) -> Sale:
    return _load_sale_with_relations(session, sale_id)
