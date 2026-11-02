# API contract proposal

## Conventions

This is a proposed versioned same-origin JSON API (`/api/v1`) used by the responsive browser UI. It is not a final contract until the listed business decisions are approved. Use JSON request/response bodies, ISO-8601 timestamps with timezone, decimal amounts serialized as strings, pagination (`limit`, `cursor` or `offset` consistently selected), and stable error objects. HTML page routes can render dashboard, product, checkout, sales and report views using the same service layer.

Success envelope recommendation: resource JSON directly for single resources; list responses include `items` and pagination metadata. Error format: `{ "error": { "code": "...", "message": "...", "details": {}, "request_id": "..." } }`. Never return stack traces or secret values.

## Proposed endpoints

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
| `POST /api/v1/sales` | Create/post checkout | Authenticated; request contains client cart and payment data; server recalculates all totals. Whether draft and post are separate endpoints is TBD. |
| `GET /api/v1/sales?from=&to=&q=&status=` | Sales history | Authenticated; paginated. |
| `GET /api/v1/sales/{id}` | Sale details | Authenticated. |
| `GET /api/v1/sales/{id}/receipt` | Printable HTML receipt | Authenticated; print CSS; access and receipt content policy TBD. |
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
