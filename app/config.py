"""Environment-backed application settings."""

from functools import lru_cache
from typing import Literal

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.image_storage import validate_r2_endpoint_url


class Settings(BaseSettings):
    """Runtime configuration; secrets are supplied through the environment."""

    model_config = SettingsConfigDict(
        env_prefix="SPARE_PARTS_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    environment: Literal["development", "test", "production"] = "development"
    database_url: str = "postgresql+psycopg://localhost:5432/spare_parts"
    debug: bool = False
    cookie_secure: bool = True
    native_https_required: bool = True
    session_idle_seconds: int = Field(default=30 * 60, gt=0)
    session_absolute_seconds: int = Field(default=12 * 60 * 60, gt=0)
    login_failure_limit: int = Field(default=5, gt=0)
    login_window_seconds: int = Field(default=15 * 60, gt=0)
    login_lockout_seconds: int = Field(default=15 * 60, gt=0)
    session_activity_write_interval_seconds: int = Field(default=60, gt=0)
    native_access_token_seconds: int = Field(default=10 * 60, gt=0, le=60 * 60)
    native_session_idle_seconds: int = Field(default=30 * 60, gt=0)
    native_session_absolute_seconds: int = Field(default=12 * 60 * 60, gt=0)
    login_throttle_retention_seconds: int = Field(default=24 * 60 * 60, gt=0, le=7 * 24 * 60 * 60)
    auth_event_retention_days: int = Field(default=90, gt=0, le=365)
    product_image_max_bytes: int = Field(default=5 * 1024 * 1024, gt=0, le=20 * 1024 * 1024)
    product_image_max_pixels: int = Field(default=20_000_000, gt=0, le=40_000_000)
    product_image_storage_path: str = "var/product-images"
    product_image_storage_backend: Literal["local", "r2"] = "local"
    r2_endpoint_url: str | None = None
    r2_bucket: str | None = None
    r2_access_key_id: str | None = None
    r2_secret_access_key: str | None = None

    @model_validator(mode="after")
    def validate_production_configuration(self) -> "Settings":
        if self.environment == "production":
            if "database_url" not in self.model_fields_set:
                raise ValueError(
                    "SPARE_PARTS_DATABASE_URL must be explicitly configured in production."
                )
            if not self.database_url.startswith("postgresql+psycopg://"):
                raise ValueError(
                    "Production requires a PostgreSQL URL using the installed psycopg driver."
                )
            if not self.cookie_secure or not self.native_https_required:
                raise ValueError("Production requires secure cookies and native HTTPS enforcement.")
            if self.product_image_storage_backend != "r2":
                raise ValueError(
                    "Production requires SPARE_PARTS_PRODUCT_IMAGE_STORAGE_BACKEND='r2'."
                )

        if self.product_image_storage_backend == "r2":
            required = (
                ("r2_endpoint_url", "SPARE_PARTS_R2_ENDPOINT_URL"),
                ("r2_bucket", "SPARE_PARTS_R2_BUCKET"),
                ("r2_access_key_id", "SPARE_PARTS_R2_ACCESS_KEY_ID"),
                ("r2_secret_access_key", "SPARE_PARTS_R2_SECRET_ACCESS_KEY"),
            )
            missing = [
                env_name
                for attr, env_name in required
                if not (getattr(self, attr) or "").strip()
            ]
            if missing:
                raise ValueError(
                    f"R2 product image storage requires: {', '.join(missing)}."
                )
            validate_r2_endpoint_url(
                self.r2_endpoint_url or "",
                require_https=self.environment == "production",
            )
            bucket = (self.r2_bucket or "").strip()
            if "/" in bucket or any(ch.isspace() for ch in bucket):
                raise ValueError(
                    "SPARE_PARTS_R2_BUCKET must be a single bucket name "
                    "without slashes or whitespace."
                )
        return self


@lru_cache
def get_settings() -> Settings:
    """Return process settings, loading values from prefixed environment variables."""
    return Settings()
