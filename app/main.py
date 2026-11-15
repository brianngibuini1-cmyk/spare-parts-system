"""FastAPI application factory and health endpoints."""

import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.exception_handlers import request_validation_exception_handler
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth import (
    CSRF_COOKIE_NAME,
    SESSION_COOKIE_NAME,
    AuthContext,
    InvalidCredentials,
    LoginTemporarilyLimited,
    authenticate_owner,
    get_current_auth,
    get_optional_auth_context,
    require_csrf,
)
from app.config import Settings, get_settings
from app.database import create_database_engine, create_session_factory, get_session
from app.models import AuthEvent, utc_now
from app.catalogue_routes import router as catalogue_router
from app.inventory_routes import inventory_router, suppliers_router
from app.reports_routes import dashboard_router, reports_router
from app.sales_routes import sales_router
from app.image_storage import LocalProductImageStorage
from app.native_auth import router as native_auth_router
from app.upload_limits import ProductImageBodyLimitMiddleware

BASE_DIR = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
logger = logging.getLogger(__name__)


class LoginRequest(BaseModel):
    login_name: str = Field(max_length=254)
    password: str = Field(max_length=1024)


def _same_origin(request: Request) -> bool:
    origin = request.headers.get("origin")
    if not origin:
        return False
    parsed = urlsplit(origin)
    expected_scheme = "https" if request.app.state.settings.cookie_secure else request.url.scheme
    host_matches = parsed.netloc.lower() == request.headers.get("host", "").lower()
    return host_matches and parsed.scheme == expected_scheme


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create an independently configurable application instance."""
    app_settings = settings or get_settings()
    engine = create_database_engine(app_settings.database_url)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        yield
        engine.dispose()

    application = FastAPI(
        title="Spare Parts Management System",
        version="0.1.0",
        debug=app_settings.debug,
        lifespan=lifespan,
    )
    application.state.settings = app_settings
    application.state.engine = engine
    application.state.session_factory = create_session_factory(engine)
    application.state.product_image_storage = LocalProductImageStorage(
        app_settings.product_image_storage_path, BASE_DIR / "static"
    )
    application.add_middleware(
        ProductImageBodyLimitMiddleware,
        max_image_bytes=app_settings.product_image_max_bytes,
    )
    application.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

    @application.exception_handler(SQLAlchemyError)
    async def database_error_handler(request: Request, exc: SQLAlchemyError):
        # SQLAlchemy exception strings can include bound values such as token hashes.
        logger.error("Database operation failed; error_type=%s", type(exc).__name__)
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"detail": "Database temporarily unavailable."},
        )

    @application.exception_handler(RequestValidationError)
    async def validation_error_handler(request: Request, exc: RequestValidationError):
        if request.url.path.startswith("/api/v1/native/auth/") or request.url.path == "/api/v1/attendants":
            # FastAPI validation details may include submitted values, which can
            # contain passwords or refresh credentials.
            return JSONResponse(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                content={"detail": "Invalid authentication request."},
            )
        return await request_validation_exception_handler(request, exc)

    @application.middleware("http")
    async def security_headers(request: Request, call_next):
        response = await call_next(request)
        response.headers.setdefault(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; "
            "base-uri 'self'; form-action 'self'; frame-ancestors 'none'",
        )
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        response.headers.setdefault("X-Frame-Options", "DENY")
        return response

    @application.get("/login", include_in_schema=False)
    def login_page(request: Request) -> Any:
        return templates.TemplateResponse(request, "login.html", {})

    @application.post("/api/v1/auth/login", tags=["authentication"])
    def login(payload: LoginRequest, request: Request, session: Session = Depends(get_session)) -> Response:
        if not _same_origin(request):
            raise HTTPException(status_code=403, detail="Request origin rejected.")
        try:
            owner, _, token, csrf_token = authenticate_owner(
                session,
                payload.login_name,
                payload.password,
                application.state.settings,
                request.client.host if request.client else None,
            )
        except LoginTemporarilyLimited:
            raise HTTPException(status_code=429, detail="Login temporarily unavailable.")
        except InvalidCredentials:
            raise HTTPException(status_code=401, detail="Invalid login name or password.")
        response = JSONResponse({"login_name": owner.login_name})
        secure = application.state.settings.cookie_secure
        response.set_cookie(SESSION_COOKIE_NAME, token, max_age=application.state.settings.session_absolute_seconds,
                            httponly=True, secure=secure, samesite="lax", path="/")
        response.set_cookie(CSRF_COOKIE_NAME, csrf_token, max_age=application.state.settings.session_absolute_seconds,
                            httponly=False, secure=secure, samesite="strict", path="/")
        return response

    @application.post("/api/v1/auth/logout", status_code=204, tags=["authentication"])
    def logout(request: Request, context: AuthContext = Depends(get_current_auth),
               session: Session = Depends(get_session)) -> Response:
        if context.transport != "cookie":
            raise HTTPException(status_code=400, detail="Use the native logout endpoint.")
        require_csrf(request, context)
        context.session.revoked_at = utc_now()
        session.add(AuthEvent(actor_id=context.user.id, event_type="logout"))
        session.commit()
        response = Response(status_code=204)
        response.delete_cookie(SESSION_COOKIE_NAME, path="/")
        response.delete_cookie(CSRF_COOKIE_NAME, path="/")
        return response

    @application.get("/api/v1/auth/me", tags=["authentication"])
    def current_user(context: AuthContext = Depends(get_current_auth)) -> dict[str, str]:
        return {"login_name": context.user.login_name, "role": context.user.role}

    @application.get("/", include_in_schema=False)
    def home(request: Request, context: AuthContext | None = Depends(get_optional_auth_context)) -> Any:
        if context is None:
            return RedirectResponse("/login", status_code=303)
        return templates.TemplateResponse(
            request,
            "index.html",
            {"active_page": "dashboard", "owner_login": context.user.login_name, "user_role": context.user.role},
        )

    @application.get("/demo", include_in_schema=False)
    def demonstration(request: Request) -> Any:
        """Render the isolated, browser-only product demonstration."""
        return templates.TemplateResponse(request, "demo.html", {})

    @application.get("/health/live", tags=["health"])
    def liveness() -> dict[str, str]:
        """Indicate that the process can serve requests; no dependency checks."""
        return {"status": "ok"}

    @application.get("/health/ready", tags=["health"], response_model=None)
    def readiness() -> JSONResponse | dict[str, str]:
        """Verify the configured database accepts a simple query."""
        session_factory = application.state.session_factory
        try:
            with session_factory() as session:
                session.execute(text("SELECT 1"))
        except SQLAlchemyError:
            return JSONResponse(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                content={"status": "unavailable", "database": "unavailable"},
            )
        return {"status": "ok", "database": "ok"}

    application.include_router(catalogue_router)
    application.include_router(suppliers_router)
    application.include_router(inventory_router)
    application.include_router(sales_router)
    application.include_router(dashboard_router)
    application.include_router(reports_router)
    application.include_router(native_auth_router)
    return application


def get_application() -> FastAPI:
    """Return the module-level application for database dependency resolution."""
    return app


app = create_app()
