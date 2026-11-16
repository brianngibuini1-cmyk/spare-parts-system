"""Private product-image storage adapters and safe image normalization."""

from __future__ import annotations

import io
import re
import secrets
import warnings
from collections.abc import Mapping
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import urlsplit

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError
from PIL import Image, UnidentifiedImageError

_KEY_PATTERN = re.compile(r"^[a-f0-9]{32}\.(?:jpg|png|webp)$")
_FORMATS = {
    "JPEG": ("image/jpeg", "jpg"),
    "PNG": ("image/png", "png"),
    "WEBP": ("image/webp", "webp"),
}
_EXTENSION_CONTENT_TYPES = {
    "jpg": "image/jpeg",
    "png": "image/png",
    "webp": "image/webp",
}
_ALLOWED_CONTENT_TYPES = frozenset(_EXTENSION_CONTENT_TYPES.values())


class InvalidProductImage(ValueError):
    """Uploaded bytes are not an allowed, decodable product photograph."""


class ProductImageTooLarge(ValueError):
    """Uploaded image exceeds a configured byte or pixel limit."""


class ProductImageStorageError(RuntimeError):
    """Underlying product-image storage backend failed."""


class ProductImageStorage(Protocol):
    """Private image storage interface; cloud object storage can implement this later."""

    def save(self, data: bytes, extension: str) -> str: ...

    def load(self, key: str) -> bytes | None: ...

    def delete(self, key: str) -> None: ...


def normalize_product_image(data: bytes, max_pixels: int) -> tuple[bytes, str, str]:
    """Decode, validate and re-encode a single JPEG, PNG or WebP image."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as image:
                image_format = image.format
                if image_format not in _FORMATS:
                    raise InvalidProductImage("Only JPEG, PNG, and WebP photographs are accepted.")
                if image.width * image.height > max_pixels:
                    raise ProductImageTooLarge("Image dimensions exceed the configured limit.")
                if getattr(image, "n_frames", 1) != 1:
                    raise InvalidProductImage("Animated images are not accepted.")
                image.verify()

            with Image.open(io.BytesIO(data)) as image:
                image_format = image.format
                if image_format not in _FORMATS:
                    raise InvalidProductImage("Only JPEG, PNG, and WebP photographs are accepted.")
                if image.width * image.height > max_pixels or getattr(image, "n_frames", 1) != 1:
                    raise ProductImageTooLarge("Image dimensions exceed the configured limit.")
                image.load()
                mime, extension = _FORMATS[image_format]
                output = io.BytesIO()
                has_alpha = "A" in image.getbands() or "transparency" in image.info
                mode = "RGB" if image_format == "JPEG" or not has_alpha else "RGBA"
                clean = Image.new(mode, image.size)
                clean.paste(image.convert(mode))
                clean.save(output, format=image_format)
                return output.getvalue(), mime, extension
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
        raise InvalidProductImage("Uploaded file is not a valid supported image.") from exc


def _validate_image_key(key: str) -> str:
    if not isinstance(key, str) or not _KEY_PATTERN.fullmatch(key):
        raise ValueError("Invalid image storage key.")
    return key


def _validate_image_extension(extension: str) -> str:
    if extension not in _EXTENSION_CONTENT_TYPES:
        raise ValueError("Invalid image extension.")
    return extension


def validate_r2_endpoint_url(endpoint_url: str, *, require_https: bool = False) -> str:
    """Validate an R2 endpoint as an absolute HTTP(S) origin without path, query, or creds."""
    clean = endpoint_url.strip()
    if not clean or any(ch.isspace() for ch in clean):
        raise ValueError("SPARE_PARTS_R2_ENDPOINT_URL must be a valid absolute URL.")
    parsed = urlsplit(clean)
    allowed_schemes = {"https"} if require_https else {"http", "https"}
    if parsed.scheme not in allowed_schemes or not parsed.netloc or not parsed.hostname:
        scheme_label = "HTTPS" if require_https else "HTTP/HTTPS"
        raise ValueError(f"SPARE_PARTS_R2_ENDPOINT_URL must be a valid {scheme_label} URL.")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("SPARE_PARTS_R2_ENDPOINT_URL must not contain embedded credentials.")
    host_port = parsed.netloc.rsplit("@", 1)[-1]
    if host_port.endswith(":"):
        raise ValueError("SPARE_PARTS_R2_ENDPOINT_URL has an invalid port.")
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError("SPARE_PARTS_R2_ENDPOINT_URL has an invalid port.") from exc
    if port is not None and port < 1:
        raise ValueError("SPARE_PARTS_R2_ENDPOINT_URL has an invalid port.")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ValueError(
            "SPARE_PARTS_R2_ENDPOINT_URL must not contain a path, query string, or fragment."
        )
    return clean.rstrip("/")


def _is_missing_object_error(exc: ClientError) -> bool:
    error_code = str(exc.response.get("Error", {}).get("Code", ""))
    status_code = exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
    return error_code in {"NoSuchKey", "404", "NotFound"} or status_code == 404


class LocalProductImageStorage:
    """Filesystem adapter storing generated opaque keys outside the public static tree."""

    def __init__(self, root: str | Path, public_root: str | Path) -> None:
        self.root = Path(root).expanduser().resolve()
        public = Path(public_root).expanduser().resolve()
        if self.root == public or public in self.root.parents:
            raise ValueError("Product image storage must be outside the public static directory.")
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)

    def _path(self, key: str) -> Path:
        validated = _validate_image_key(key)
        path = (self.root / validated).resolve()
        if path.parent != self.root:
            raise ValueError("Invalid image storage key.")
        return path

    def save(self, data: bytes, extension: str) -> str:
        validated_ext = _validate_image_extension(extension)
        key = f"{secrets.token_hex(16)}.{validated_ext}"
        path = self._path(key)
        descriptor = None
        try:
            descriptor = path.open("xb")
            try:
                import os

                os.chmod(path, 0o600)
            except OSError:
                pass
            descriptor.write(data)
        finally:
            if descriptor is not None:
                descriptor.close()
        return key

    def load(self, key: str) -> bytes | None:
        path = self._path(key)
        try:
            return path.read_bytes()
        except FileNotFoundError:
            return None

    def delete(self, key: str) -> None:
        path = self._path(key)
        try:
            path.unlink()
        except FileNotFoundError:
            return


class R2ProductImageStorage:
    """Private Cloudflare R2 (S3-compatible) adapter storing generated opaque keys."""

    def __init__(
        self,
        *,
        endpoint_url: str,
        bucket: str,
        access_key_id: str,
        secret_access_key: str,
        max_bytes: int = 5 * 1024 * 1024,
        client: Any | None = None,
        connect_timeout: float = 5.0,
        read_timeout: float = 15.0,
        max_attempts: int = 3,
    ) -> None:
        clean_endpoint = endpoint_url.strip()
        clean_bucket = bucket.strip()
        clean_access_key = access_key_id.strip()
        clean_secret_key = secret_access_key.strip()
        if not clean_endpoint or not clean_bucket or not clean_access_key or not clean_secret_key:
            raise ValueError("R2 product image storage configuration is incomplete.")
        clean_endpoint = validate_r2_endpoint_url(clean_endpoint)
        if "/" in clean_bucket or any(ch.isspace() for ch in clean_bucket):
            raise ValueError("Invalid R2 bucket name.")
        if max_bytes <= 0:
            raise ValueError("max_bytes must be positive.")

        self._bucket = clean_bucket
        self._max_bytes = max_bytes
        if client is not None:
            self._client = client
        else:
            config = Config(
                region_name="auto",
                signature_version="s3v4",
                connect_timeout=connect_timeout,
                read_timeout=read_timeout,
                retries={"max_attempts": max_attempts, "mode": "standard"},
                s3={"addressing_style": "path"},
            )
            self._client = boto3.client(
                "s3",
                endpoint_url=clean_endpoint,
                aws_access_key_id=clean_access_key,
                aws_secret_access_key=clean_secret_key,
                region_name="auto",
                config=config,
            )

    def save(self, data: bytes, extension: str) -> str:
        validated_ext = _validate_image_extension(extension)
        key = f"{secrets.token_hex(16)}.{validated_ext}"
        _validate_image_key(key)
        content_type = _EXTENSION_CONTENT_TYPES[validated_ext]
        try:
            self._client.put_object(
                Bucket=self._bucket,
                Key=key,
                Body=data,
                ContentType=content_type,
            )
        except (BotoCoreError, ClientError) as exc:
            raise ProductImageStorageError("Failed to save product image to R2.") from exc
        return key

    def load(self, key: str) -> bytes | None:
        validated_key = _validate_image_key(key)
        try:
            response = self._client.get_object(Bucket=self._bucket, Key=validated_key)
        except ClientError as exc:
            if _is_missing_object_error(exc):
                return None
            raise ProductImageStorageError("Failed to load product image from R2.") from exc
        except BotoCoreError as exc:
            raise ProductImageStorageError("Failed to load product image from R2.") from exc

        if not isinstance(response, Mapping):
            raise ProductImageStorageError("Unexpected R2 response payload.")

        body = response.get("Body")
        extension = validated_key.rsplit(".", 1)[1]
        expected_type = _EXTENSION_CONTENT_TYPES[extension]
        completed = False
        try:
            content_type = response.get("ContentType")
            if not isinstance(content_type, str):
                raise ProductImageStorageError("R2 object is missing a valid content type.")
            normalized_type = content_type.split(";", 1)[0].strip().lower()
            if normalized_type not in _ALLOWED_CONTENT_TYPES:
                raise ProductImageStorageError("R2 object has an unsupported content type.")
            if normalized_type != expected_type:
                raise ProductImageStorageError(
                    "R2 object content type does not match the image key."
                )

            content_length = response.get("ContentLength")
            if content_length is not None:
                if (
                    isinstance(content_length, bool)
                    or not isinstance(content_length, int)
                    or content_length < 0
                ):
                    raise ProductImageStorageError("R2 object has invalid content length.")
                if content_length > self._max_bytes:
                    raise ProductImageStorageError(
                        "R2 object exceeds the maximum allowed image size."
                    )

            if body is None or not callable(getattr(body, "read", None)):
                raise ProductImageStorageError("R2 response is missing a readable body stream.")

            chunks: list[bytes] = []
            total_read = 0
            max_read = self._max_bytes + 1
            while True:
                remaining = max_read - total_read
                chunk_size = min(remaining, 64 * 1024)
                chunk = body.read(chunk_size)
                if not isinstance(chunk, (bytes, bytearray)):
                    raise ProductImageStorageError("R2 response body returned non-bytes data.")
                if not chunk:
                    break
                chunks.append(bytes(chunk))
                total_read += len(chunk)
                if total_read > self._max_bytes:
                    raise ProductImageStorageError(
                        "R2 object exceeds the maximum allowed image size."
                    )
            completed = True
            return b"".join(chunks)
        except ProductImageStorageError:
            raise
        except Exception as exc:
            raise ProductImageStorageError(
                "Failed to read product image stream from R2."
            ) from exc
        finally:
            try:
                close = getattr(body, "close", None)
                if callable(close):
                    close()
            except Exception as close_exc:
                if completed:
                    raise ProductImageStorageError(
                        "Failed to close product image stream from R2."
                    ) from close_exc

    def delete(self, key: str) -> None:
        validated_key = _validate_image_key(key)
        try:
            self._client.delete_object(Bucket=self._bucket, Key=validated_key)
        except ClientError as exc:
            if _is_missing_object_error(exc):
                return
            raise ProductImageStorageError("Failed to delete product image from R2.") from exc
        except BotoCoreError as exc:
            raise ProductImageStorageError("Failed to delete product image from R2.") from exc
