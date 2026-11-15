# API contract proposal

## Conventions

This is a proposed versioned JSON API (`/api/v1`) consumed by the Windows, Android and iOS Flutter clients. The native clients use HTTPS; browser routes are legacy/demo support, not the production UI. It is not a final contract until the listed business decisions are approved. Use JSON request/response bodies, ISO-8601 timestamps with timezone, decimal amounts serialized as strings, pagination (`limit`, `cursor` or `offset` consistently selected), and stable error objects.

Success envelope recommendation: resource JSON directly for single resources; list responses include `items` and pagination metadata. Error format: `{ "error": { "code": "...", "message": "...", "details": {}, "request_id": "..." } }`. Never return stack traces or secret values.

## Existing browser authentication endpoints

| Method and path | Behavior | Access / protections |
|---|---|---|
| `GET /login` | Owner sign-in page | Public. |
| `POST /api/v1/auth/login` | JSON `{ "login_name": "...", "password": "..." }`; issues an opaque server-side session and CSRF cookie | Public; same-origin `Origin` required; generic `401`; `429` when the observed client peer is throttled. |
| `POST /api/v1/auth/logout` | Revokes current session and clears cookies | Authenticated; matching CSRF cookie/header required. Returns `204`. |
| `GET /api/v1/auth/me` | Returns `{ "login_name": "...", "role": "owner|attendant" }` | Authenticated; `401` without a valid session. |

The dashboard (`GET /`) redirects unauthenticated browsers to `/login`. The existing `/demo` page is intentionally public and isolated from business records. No stock, receiving, sales or checkout API is implemented.

## Native Flutter authentication API

All routes below are implemented under `/api/v1/native/auth`. Require HTTPS in every deployed environment. Never send tokens in URLs. Login and refresh credentials appear only in JSON bodies; access credentials appear in `Authorization: Bearer ...`. Tokens are opaque, random, and hashed in PostgreSQL. Existing cookie endpoints continue to work separately.

### `POST /api/v1/native/auth/login`

Request:

```json
{"login_name":"owner@example.test","password":"<password>"}
```

Successful response (`200`):

```json
{
  "access_token":"<opaque-access-token>",
  "token_type":"Bearer",
  "expires_in":600,
  "access_expires_at":"2026-11-04T10:10:00+00:00",
  "refresh_token":"<opaque-refresh-token>",
  "refresh_expires_at":"2026-11-04T10:30:00+00:00",
  "session_expires_at":"2026-11-04T22:00:00+00:00",
  "user":{"id":1,"login_name":"owner@example.test","role":"OWNER"}
}
```

`role` is loaded from the user record and is either `OWNER` or `SHOP_ATTENDANT`. Clients cannot choose a role. Invalid credentials return `401 {"detail":"Invalid login name or password."}`; a throttled peer receives `429 {"detail":"Authentication temporarily unavailable."}`. Request validation errors return `422 {"detail":"Invalid authentication request."}` without echoing submitted credentials. Database failures return a generic `503`.

### `POST /api/v1/native/auth/refresh`

Request body:

```json
{"refresh_token":"<current-refresh-token>"}
```

Success returns the same token response as login with new access and refresh tokens. The submitted refresh token is consumed once. A second use revokes the whole native session family, records a reuse audit event, and returns generic `401 {"detail":"Invalid or expired session."}`. Expired, revoked, missing, or malformed tokens receive the same generic `401` response. PostgreSQL serializes rotations on the session row; a partial unique index also permits at most one unconsumed refresh token per session. A process-local lock helps serialize same-worker requests in development; production correctness across workers relies on the database lock and constraint.

### `POST /api/v1/native/auth/logout`

Request body:

```json
{"refresh_token":"<current-or-previous-refresh-token>"}
```

Success returns `204` and revokes the server-side session, invalidating its access token and all refresh tokens. Flutter must erase both locally stored tokens whether logout succeeds or the session is already invalid. Invalid credentials return the generic session `401` response.

### `GET /api/v1/native/auth/me`

Send the access token in the authorization header:

```http
Authorization: Bearer <access-token>
```

Response (`200`):

```json
{
  "id":1,
  "login_name":"owner@example.test",
  "role":"OWNER",
  "session_idle_expires_at":"2026-11-04T10:30:00+00:00",
  "session_expires_at":"2026-11-04T22:00:00+00:00",
  "access_expires_at":"2026-11-04T10:10:00+00:00"
}
```

Protected operational APIs accept either their existing browser session cookie or a valid native bearer access token. If an `Authorization` header is present but malformed/invalid/expired, the request is rejected with `401` and `WWW-Authenticate: Bearer`; the server does not fall back to a browser cookie. Existing mutations retain CSRF checks for cookie requests; bearer-authenticated native requests do not use browser CSRF tokens. Every operation still enforces permissions using the persisted role.

### Flutter session behavior and provisional lifetimes

Provisional defaults (not client-approved policy): access token lifetime **10 minutes**; refresh idle lifetime **30 minutes from successful refresh**; absolute native session lifetime **12 hours**. Configure with `SPARE_PARTS_NATIVE_ACCESS_TOKEN_SECONDS`, `SPARE_PARTS_NATIVE_SESSION_IDLE_SECONDS`, and `SPARE_PARTS_NATIVE_SESSION_ABSOLUTE_SECONDS`. These values must be reviewed before production. `SPARE_PARTS_NATIVE_HTTPS_REQUIRED=true` is the default and enforces HTTPS independently of cookie settings. The refresh token's effective expiry is the earlier idle or absolute session expiry. API calls do not extend refresh idle expiry; clients should refresh before access expiry during active use. Flutter must use a single-flight refresh lock per session: concurrent submissions of the same refresh token are treated as reuse and revoke that session. On refresh, atomically replace both credentials and persist the new pair in OS secure storage before discarding the old pair. If refresh fails, clear local credentials and require sign-in. Never retry a consumed refresh token after a network timeout; query `/me` with any new access token if received, otherwise require login after generic failure/reuse revocation.

The owner-protected attendant provisioning API remains `POST /api/v1/attendants`; it is not public registration and accepts native bearer authorization. The server assigns `SHOP_ATTENDANT`; no endpoint accepts a client-supplied role, and existing APIs do not permit role changes. Account creation and activation/deactivation are recorded as auth audit events. If role changes are needed later, add an explicit owner-only audited workflow.

## Product catalogue endpoints implemented

All catalogue endpoints require an authenticated owner or attendant session. Browser-cookie mutations require the session's CSRF cookie value in `X-CSRF-Token`; native clients authenticate with bearer access tokens and do not send browser CSRF tokens.

| Method and path | Access and behavior |
|---|---|
| `GET /api/v1/products?q=&approval_status=&limit=` | Owner sees all statuses; attendant sees approved products and their own submissions. Search includes name, reference, category and manufacturer part number. |
| `POST /api/v1/products` | Owner or attendant creates a pending submission. Server generates the internal reference. Client-supplied status or price is rejected. |
| `GET /api/v1/products/{id}` / `PATCH /api/v1/products/{id}` | Owner reads/edits non-rejected product details; attendant reads approved products and their own submissions, and edits only their own pending products. |
| `GET /api/v1/products/pending` | Owner-only approval queue. |
| `POST /api/v1/products/{id}/approve` | Owner-only; requires a validated decimal price and records approver/time. Can update an approved price by reapproval. |
| `POST /api/v1/products/{id}/reject` | Owner-only; requires a reason and preserves the rejected product/history. |
| `POST /api/v1/products/{id}/image` / `GET /api/v1/products/{id}/image` | Authenticated; upload/edit follows product permissions; retrieval checks visibility. Only decoded JPEG/PNG/WebP are stored. |
| `GET /api/v1/attendants` / `POST /api/v1/attendants` / `PATCH /api/v1/attendants/{id}` | Owner-only list, create and activate/deactivate attendant accounts. |

HTML pages are `/products`, `/products/{id}`, `/products/approvals` (owner-only) and `/team` (owner-only). Product prices are `NUMERIC(18,4)` values with no currency or tax semantics yet. No stock, receiving, sales or checkout API is implemented.

## Proposed future business endpoints

| Method and path | Purpose / access | Notes |
|---|---|---|
| `POST /api/v1/auth/login` | Authenticate owner | Rate limited; generic failure message; secure session cookie. |
| `POST /api/v1/auth/logout` | Revoke current session | Authenticated; CSRF protected. |
| `GET /api/v1/auth/me` | Current user summary | Authenticated. |
| `POST /api/v1/auth/password` | Change password | Authenticated; require current credential and re-auth policy. |
| `GET /api/v1/dashboard?from=&to=` | Dashboard aggregates | Authenticated; metric definitions TBD. |
| `GET /api/v1/products?q=&active=&limit=&cursor=` | Search/list products | Authenticated. |
| `POST /api/v1/products` | Create product | Authenticated; field/uniqueness rules TBD. |
| `GET /api/v1/products/{id}` | Product detail incl. current stock | Authenticated. |
| `PATCH /api/v1/products/{id}` | Edit product metadata | Authenticated; avoid rewriting historical line snapshots. |
| `POST /api/v1/products/{id}/deactivate` | Deactivate product | Authenticated; preserve history. |
| `GET /api/v1/products/{id}/stock-movements?from=&to=` | Inventory ledger history | Authenticated. |
| `GET /api/v1/suppliers?q=&active=` | List/search suppliers | Authenticated. |
| `POST /api/v1/suppliers` | Create supplier | Authenticated. |
| `GET /api/v1/suppliers/{id}` / `PATCH ...` | Read/edit supplier | Authenticated; history preserved. |
| `POST /api/v1/purchases` | Create draft purchase | Authenticated; lifecycle TBD. |
| `GET /api/v1/purchases/{id}` / `PATCH ...` | Read/edit permitted draft | Authenticated; posted record rules TBD. |
| `POST /api/v1/purchases/{id}/receive` | Post received quantities | Authenticated; atomic stock movement creation; idempotency key. |
| `POST /api/v1/sales` | Create/post sale | Authenticated (owner/attendant); idempotency key; accepts `payment_method` (`cash` or manual `mpesa`), `amount_tendered`, optional `payment_reference`/`notes`, and `lines[{product_id, quantity}]`; server resolves approved product prices, calculates totals/change, rejects partial/split/excess-M-PESA payments (`422`) and insufficient stock (`409`), and atomically deducts stock. |
| `GET /api/v1/sales?q=&limit=&offset=` | Sales history | Authenticated; paginated, ordered newest first, searchable by `receipt_number` or `payment_reference`. |
| `GET /api/v1/sales/{id}` | Sale & receipt details | Authenticated; returns sale header, payment summary, and immutable product/price line snapshots. |
| `GET /api/v1/sales/{id}/receipt` | Printable HTML receipt | Planned/future; print CSS; access and receipt content policy TBD. |
| `GET /api/v1/reports/sales?from=&to=&group_by=` | Sales summary/detail report | Authenticated; groupings and export format TBD. |
| `GET /api/v1/reports/inventory` | Stock listing/report | Authenticated; valuation inclusion TBD. |
| `GET /api/v1/audit-events?from=&to=&actor=&entity=` | Audit search | Owner authenticated; scope/retention TBD. |

## Example checkout payload (illustrative only)

```json
{
  "items": [
    {"product_id": "uuid", "quantity": "2"}
  ],
  "payment": {"method": "UNDECIDED", "amount": "0.00"},
  "idempotency_key": "client-generated-unique-value"
}
```

The payment fields above are placeholders and must not be implemented as business policy. Client-supplied prices/totals are not trusted. The server resolves product/pricing and computes the final amount using approved rules.

## Status and error semantics

- `200` read/update success; `201` created; `204` logout/deactivation where body is unnecessary.
- `400` malformed or semantically invalid request; `401` no valid session; `403` authenticated but disallowed; `404` unknown resource; `409` duplicate/idempotency conflict, stale state, or stock-policy conflict; `422` field validation; `429` rate limit; `500` generic unexpected error.
- Define stable machine-readable codes such as `validation_error`, `stock_conflict`, `duplicate_reference`, `not_found`, `authentication_failed`.
- Checkout and receipt POST operations must be retry-safe and atomic. Record request IDs for troubleshooting, never expose database internals.

## Contract decisions before implementation

Confirm session/auth flow, product fields, checkout stages, payment/tax/discount schema, sale and purchase status transitions, corrections/returns, paging strategy, filter semantics, report/export requirements, and all date/timezone behavior. Generate OpenAPI from FastAPI once implementation begins and review it against this proposal.
