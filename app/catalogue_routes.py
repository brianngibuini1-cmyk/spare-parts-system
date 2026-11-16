"""Owner/attendant APIs and responsive product catalogue pages."""

from __future__ import annotations

import logging
import uuid
from decimal import Decimal
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, Depends, File, HTTPException, Query, Request, UploadFile
from fastapi.responses import HTMLResponse, Response
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import or_, select, update
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth import (
    AuthContext,
    InvalidOwnerInput,
    can_view_product,
    get_current_auth,
    provision_attendant,
    require_csrf,
    require_owner,
)
from app.database import get_session
from app.image_storage import (
    InvalidProductImage,
    ProductImageStorageError,
    ProductImageTooLarge,
    normalize_product_image,
)
from app.models import (
    AuthEvent,
    AuthSession,
    NativeAuthSession,
    Product,
    ProductEvent,
    UserAccount,
    utc_now,
)

router = APIRouter()
logger = logging.getLogger(__name__)
templates = Jinja2Templates(directory=str(Path(__file__).resolve().parent / "templates"))
MAX_PRICE = Decimal("99999999999999.9999")


class StrictInput(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class ProductCreate(StrictInput):
    name: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=4000)
    category: str | None = Field(default=None, max_length=100)
    manufacturer_part_number: str | None = Field(default=None, max_length=128)


class ProductUpdate(StrictInput):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=4000)
    category: str | None = Field(default=None, max_length=100)
    manufacturer_part_number: str | None = Field(default=None, max_length=128)

    @field_validator("name")
    @classmethod
    def reject_explicit_null_name(cls, value: str | None) -> str | None:
        if value is None:
            raise ValueError("Product name cannot be null.")
        return value


def _validate_price(value: Decimal) -> Decimal:
    if not value.is_finite() or value < 0 or value > MAX_PRICE:
        raise ValueError("Selling price is outside the supported decimal range.")
    if value.as_tuple().exponent < -4:
        raise ValueError("Selling price can have no more than four decimal places.")
    return value.quantize(Decimal("0.0001"))


class ProductApproval(StrictInput):
    selling_price: Decimal

    @field_validator("selling_price")
    @classmethod
    def validate_selling_price(cls, value: Decimal) -> Decimal:
        return _validate_price(value)


class ProductRejection(StrictInput):
    reason: str = Field(min_length=1, max_length=2000)


class AttendantCreate(StrictInput):
    login_name: str = Field(min_length=1, max_length=254)
    password: str = Field(min_length=15, max_length=1024)


class AttendantStatus(StrictInput):
    is_active: bool


def _event(session: Session, product: Product, actor_id: int, kind: str, detail: str | None = None) -> None:
    session.add(
        ProductEvent(product_id=product.id, actor_id=actor_id, event_type=kind, detail=detail)
    )


def _product_json(product: Product, context: AuthContext) -> dict:
    return {
        "id": str(product.id),
        "internal_reference": product.internal_reference,
        "name": product.name,
        "description": product.description,
        "category": product.category,
        "manufacturer_part_number": product.manufacturer_part_number,
        "image_url": f"/api/v1/products/{product.id}/image" if product.image_key else None,
        "selling_price": format(product.selling_price, ".4f") if product.selling_price is not None else None,
        "approval_status": product.approval_status,
        "submitted_by": product.submitted_by,
        "submitted_by_login": product.submitter.login_name,
        "submitted_at": product.submitted_at.isoformat(),
        "approved_by": product.approved_by,
        "approved_by_login": product.approver.login_name if product.approver else None,
        "approved_at": product.approved_at.isoformat() if product.approved_at else None,
        "rejection_reason": product.rejection_reason,
        "can_edit": (context.user.role == "owner" and product.approval_status != "rejected")
        or (product.submitted_by == context.user.id and product.approval_status == "pending"),
    }


def _owned_product(session: Session, product_id: uuid.UUID) -> Product:
    product = session.scalar(select(Product).where(Product.id == product_id).with_for_update())
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found.")
    return product


def _visible_product(session: Session, product_id: uuid.UUID, context: AuthContext) -> Product:
    product = session.get(Product, product_id)
    if product is None or not can_view_product(context, product):
        raise HTTPException(status_code=404, detail="Product not found.")
    return product


def _require_editable_product(product: Product, context: AuthContext) -> None:
    if context.user.role != "owner" and product.submitted_by != context.user.id:
        raise HTTPException(status_code=404, detail="Product not found.")
    if context.user.role != "owner" and product.approval_status != "pending":
        raise HTTPException(status_code=403, detail="Only your pending submissions can be edited.")
    if product.approval_status == "rejected":
        raise HTTPException(status_code=409, detail="Rejected products cannot be edited.")


@router.get("/api/v1/attendants", tags=["users"])
def list_attendants(
    _: AuthContext = Depends(require_owner), session: Session = Depends(get_session)
) -> list[dict]:
    users = session.scalars(
        select(UserAccount).where(UserAccount.role == "attendant").order_by(UserAccount.login_name)
    )
    return [
        {"id": user.id, "login_name": user.login_name, "is_active": user.is_active,
         "created_at": user.created_at.isoformat()}
        for user in users
    ]


@router.post("/api/v1/attendants", status_code=201, tags=["users"])
def create_attendant(
    payload: AttendantCreate,
    request: Request,
    context: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> dict:
    require_csrf(request, context)
    try:
        user = provision_attendant(session, payload.login_name, payload.password)
        session.add(AuthEvent(actor_id=context.user.id, event_type="attendant_created"))
        session.commit()
    except InvalidOwnerInput as exc:
        session.rollback()
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except IntegrityError as exc:
        session.rollback()
        raise HTTPException(status_code=409, detail="An account with that login name already exists.") from exc
    return {
        "id": user.id,
        "login_name": user.login_name,
        "role": "SHOP_ATTENDANT",
        "is_active": user.is_active,
    }


@router.patch("/api/v1/attendants/{user_id}", tags=["users"])
def set_attendant_status(
    user_id: int,
    payload: AttendantStatus,
    request: Request,
    context: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> dict:
    require_csrf(request, context)
    user = session.get(UserAccount, user_id)
    if user is None or user.role != "attendant":
        raise HTTPException(status_code=404, detail="Attendant not found.")
    user.is_active = payload.is_active
    if not payload.is_active:
        revoked_at = utc_now()
        session.execute(
            update(AuthSession)
            .where(AuthSession.user_id == user.id, AuthSession.revoked_at.is_(None))
            .values(revoked_at=revoked_at)
        )
        session.execute(
            update(NativeAuthSession)
            .where(
                NativeAuthSession.user_id == user.id,
                NativeAuthSession.revoked_at.is_(None),
            )
            .values(revoked_at=revoked_at)
        )
    session.add(AuthEvent(actor_id=context.user.id, event_type="attendant_status_changed"))
    session.commit()
    return {"id": user.id, "login_name": user.login_name, "is_active": user.is_active}


@router.get("/api/v1/products/pending", tags=["products"])
def pending_products(
    context: AuthContext = Depends(require_owner), session: Session = Depends(get_session)
) -> list[dict]:
    rows = session.scalars(
        select(Product).where(Product.approval_status == "pending").order_by(Product.submitted_at)
    )
    return [_product_json(product, context) for product in rows]


@router.get("/api/v1/products", tags=["products"])
def list_products(
    q: str | None = None,
    approval_status: Literal["pending", "approved", "rejected"] | None = None,
    limit: int = Query(default=50, ge=1, le=100),
    context: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> dict:
    query = select(Product)
    if context.user.role != "owner":
        query = query.where(
            or_(Product.approval_status == "approved", Product.submitted_by == context.user.id)
        )
    if approval_status:
        query = query.where(Product.approval_status == approval_status)
    if q and q.strip():
        term = f"%{q.strip()}%"
        query = query.where(
            or_(Product.name.ilike(term), Product.internal_reference.ilike(term),
                Product.category.ilike(term), Product.manufacturer_part_number.ilike(term))
        )
    rows = session.scalars(query.order_by(Product.name, Product.internal_reference).limit(limit))
    return {"items": [_product_json(product, context) for product in rows], "limit": limit}


@router.post("/api/v1/products", status_code=201, tags=["products"])
def create_product(
    payload: ProductCreate,
    request: Request,
    context: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> dict:
    require_csrf(request, context)
    product = Product(
        internal_reference=f"SP-{uuid.uuid4().hex.upper()}",
        name=payload.name,
        description=payload.description or None,
        category=payload.category or None,
        manufacturer_part_number=payload.manufacturer_part_number or None,
        approval_status="pending",
        submitted_by=context.user.id,
    )
    session.add(product)
    session.flush()
    _event(session, product, context.user.id, "submitted")
    session.commit()
    return _product_json(product, context)


@router.get("/api/v1/products/{product_id}", tags=["products"])
def get_product(
    product_id: uuid.UUID,
    context: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> dict:
    return _product_json(_visible_product(session, product_id, context), context)


@router.patch("/api/v1/products/{product_id}", tags=["products"])
def update_product(
    product_id: uuid.UUID,
    payload: ProductUpdate,
    request: Request,
    context: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> dict:
    require_csrf(request, context)
    product = _owned_product(session, product_id)
    _require_editable_product(product, context)
    changes = payload.model_dump(exclude_unset=True)
    if not changes:
        raise HTTPException(status_code=422, detail="Provide at least one product field to update.")
    if "name" in changes and not changes["name"]:
        raise HTTPException(status_code=422, detail="Product name is required.")
    for key, value in changes.items():
        setattr(product, key, value or None if key != "name" else value)
    product.updated_at = utc_now()
    _event(session, product, context.user.id, "edited")
    session.commit()
    return _product_json(product, context)


@router.post("/api/v1/products/{product_id}/approve", tags=["products"])
def approve_product(
    product_id: uuid.UUID,
    payload: ProductApproval,
    request: Request,
    context: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> dict:
    require_csrf(request, context)
    product = _owned_product(session, product_id)
    if product.approval_status == "rejected":
        raise HTTPException(status_code=409, detail="Rejected submissions cannot be approved.")
    price = _validate_price(payload.selling_price)
    product.selling_price = price
    product.approval_status = "approved"
    product.approved_by = context.user.id
    product.approved_at = utc_now()
    product.rejection_reason = None
    product.updated_at = product.approved_at
    _event(session, product, context.user.id, "approved")
    session.commit()
    return _product_json(product, context)


@router.post("/api/v1/products/{product_id}/reject", tags=["products"])
def reject_product(
    product_id: uuid.UUID,
    payload: ProductRejection,
    request: Request,
    context: AuthContext = Depends(require_owner),
    session: Session = Depends(get_session),
) -> dict:
    require_csrf(request, context)
    product = _owned_product(session, product_id)
    if product.approval_status != "pending":
        raise HTTPException(status_code=409, detail="Only pending submissions can be rejected.")
    product.approval_status = "rejected"
    product.rejection_reason = payload.reason.strip()
    product.selling_price = None
    product.approved_by = None
    product.approved_at = None
    product.updated_at = utc_now()
    _event(session, product, context.user.id, "rejected", product.rejection_reason)
    session.commit()
    return _product_json(product, context)


@router.post("/api/v1/products/{product_id}/image", tags=["products"])
def upload_product_image(
    product_id: uuid.UUID,
    request: Request,
    file: UploadFile = File(...),
    context: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> dict:
    require_csrf(request, context)
    try:
        product = _owned_product(session, product_id)
        _require_editable_product(product, context)
        limit = request.app.state.settings.product_image_max_bytes
        data = file.file.read(limit + 1)
    finally:
        file.file.close()
    if len(data) > limit:
        raise HTTPException(status_code=413, detail="Image exceeds the configured upload limit.")
    try:
        normalized, media_type, extension = normalize_product_image(
            data, request.app.state.settings.product_image_max_pixels
        )
        if len(normalized) > limit:
            raise HTTPException(status_code=413, detail="Normalized image exceeds the configured upload limit.")
    except ProductImageTooLarge as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc
    except InvalidProductImage as exc:
        raise HTTPException(status_code=415, detail=str(exc)) from exc

    storage = request.app.state.product_image_storage
    try:
        new_key = storage.save(normalized, extension)
    except (OSError, ProductImageStorageError) as exc:
        logger.error(
            "Product image upload failed; product_id=%s error_type=%s",
            product.id,
            type(exc).__name__,
        )
        raise HTTPException(status_code=500, detail="Image storage is unavailable.") from exc
    old_key = product.image_key
    product.image_key = new_key
    product.image_media_type = media_type
    product.updated_at = utc_now()
    _event(session, product, context.user.id, "image_updated")
    try:
        session.commit()
    except SQLAlchemyError as exc:
        session.rollback()
        try:
            storage.delete(new_key)
        except (OSError, ProductImageStorageError) as cleanup_exc:
            logger.warning(
                "Failed to delete rolled-back product image; product_id=%s key=%s error_type=%s",
                product.id,
                new_key,
                type(cleanup_exc).__name__,
            )
        raise HTTPException(status_code=500, detail="Image could not be saved.") from exc
    if old_key:
        try:
            storage.delete(old_key)
        except (OSError, ProductImageStorageError) as cleanup_exc:
            logger.warning(
                "Failed to delete replaced product image; product_id=%s key=%s error_type=%s",
                product.id,
                old_key,
                type(cleanup_exc).__name__,
            )
    return _product_json(product, context)


@router.get("/api/v1/products/{product_id}/image", tags=["products"])
def get_product_image(
    product_id: uuid.UUID,
    request: Request,
    context: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> Response:
    product = _visible_product(session, product_id, context)
    if not product.image_key or not product.image_media_type:
        raise HTTPException(status_code=404, detail="Product image not found.")
    try:
        data = request.app.state.product_image_storage.load(product.image_key)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="Product image not found.") from exc
    except (OSError, ProductImageStorageError) as exc:
        logger.error(
            "Product image retrieval failed; product_id=%s error_type=%s",
            product.id,
            type(exc).__name__,
        )
        raise HTTPException(status_code=500, detail="Image storage is unavailable.") from exc
    if data is None:
        raise HTTPException(status_code=404, detail="Product image not found.")
    extension = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}[product.image_media_type]
    return Response(
        data,
        media_type=product.image_media_type,
        headers={"Cache-Control": "private, no-store", "Content-Disposition": f'inline; filename="product-image.{extension}"'},
    )


@router.get("/products", response_class=HTMLResponse, include_in_schema=False)
def products_page(request: Request, context: AuthContext = Depends(get_current_auth)) -> HTMLResponse:
    return templates.TemplateResponse(
        request, "products.html", {"user_role": context.user.role, "active_page": "products"}
    )


@router.get("/products/approvals", response_class=HTMLResponse, include_in_schema=False)
def approvals_page(request: Request, _: AuthContext = Depends(require_owner)) -> HTMLResponse:
    return templates.TemplateResponse(request, "approvals.html", {"active_page": "approvals"})


@router.get("/products/{product_id}", response_class=HTMLResponse, include_in_schema=False)
def product_detail_page(
    product_id: uuid.UUID,
    request: Request,
    context: AuthContext = Depends(get_current_auth),
    session: Session = Depends(get_session),
) -> HTMLResponse:
    product = _visible_product(session, product_id, context)
    return templates.TemplateResponse(
        request,
        "product_detail.html",
        {"product": _product_json(product, context), "user_role": context.user.role},
    )


@router.get("/team", response_class=HTMLResponse, include_in_schema=False)
def team_page(request: Request, _: AuthContext = Depends(require_owner)) -> HTMLResponse:
    return templates.TemplateResponse(request, "team.html", {"active_page": "team"})
