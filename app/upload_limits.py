"""Bound upload request bodies before the multipart parser can spool them to disk."""

from __future__ import annotations

import re

_PRODUCT_IMAGE_PATH = re.compile(r"^/api/v1/products/[^/]+/image$")


class _UploadBodyTooLarge(Exception):
    pass


class ProductImageBodyLimitMiddleware:
    """ASGI request-size guard; the extra allowance is for multipart boundaries/headers."""

    def __init__(self, app, max_image_bytes: int) -> None:
        self.app = app
        self.max_request_bytes = max_image_bytes + 64 * 1024

    async def __call__(self, scope, receive, send) -> None:
        if (
            scope["type"] != "http"
            or scope["method"] != "POST"
            or not _PRODUCT_IMAGE_PATH.fullmatch(scope.get("path", ""))
        ):
            await self.app(scope, receive, send)
            return

        headers = {key.lower(): value for key, value in scope.get("headers", [])}
        try:
            content_length = int(headers.get(b"content-length", b"0"))
        except ValueError:
            content_length = 0
        if content_length > self.max_request_bytes:
            await self._reject(send)
            return

        total = 0

        async def limited_receive():
            nonlocal total
            message = await receive()
            if message["type"] == "http.request":
                total += len(message.get("body", b""))
                if total > self.max_request_bytes:
                    raise _UploadBodyTooLarge
            return message

        try:
            await self.app(scope, limited_receive, send)
        except _UploadBodyTooLarge:
            await self._reject(send)

    @staticmethod
    async def _reject(send) -> None:
        body = b'{"detail":"Image request exceeds the configured upload limit."}'
        await send(
            {
                "type": "http.response.start",
                "status": 413,
                "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())],
            }
        )
        await send({"type": "http.response.body", "body": body})
