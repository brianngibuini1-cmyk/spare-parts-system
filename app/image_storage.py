"""Private product-image storage adapters and safe image normalization."""

from __future__ import annotations

import io
import re
import secrets
import warnings
from pathlib import Path
from typing import Protocol

from PIL import Image, UnidentifiedImageError

_KEY_PATTERN = re.compile(r"^[a-f0-9]{32}\.(?:jpg|png|webp)$")
_FORMATS = {
    "JPEG": ("image/jpeg", "jpg"),
    "PNG": ("image/png", "png"),
    "WEBP": ("image/webp", "webp"),
}


class InvalidProductImage(ValueError):
    """Uploaded bytes are not an allowed, decodable product photograph."""


class ProductImageTooLarge(ValueError):
    """Uploaded image exceeds a configured byte or pixel limit."""


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


class LocalProductImageStorage:
    """Filesystem adapter storing generated opaque keys outside the public static tree."""

    def __init__(self, root: str | Path, public_root: str | Path) -> None:
        self.root = Path(root).expanduser().resolve()
        public = Path(public_root).expanduser().resolve()
        if self.root == public or public in self.root.parents:
            raise ValueError("Product image storage must be outside the public static directory.")
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)

    def _path(self, key: str) -> Path:
        if not _KEY_PATTERN.fullmatch(key):
            raise ValueError("Invalid image storage key.")
        path = (self.root / key).resolve()
        if path.parent != self.root:
            raise ValueError("Invalid image storage key.")
        return path

    def save(self, data: bytes, extension: str) -> str:
        if extension not in {"jpg", "png", "webp"}:
            raise ValueError("Invalid image extension.")
        key = f"{secrets.token_hex(16)}.{extension}"
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
