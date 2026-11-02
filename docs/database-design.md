# Database design

## Conventions

PostgreSQL is authoritative. Use UUID primary keys (or another consistently chosen non-guessable key strategy), `timestamptz` in UTC, foreign keys, `NOT NULL` where meaningful, and indexes for common search/filter paths. Money uses `numeric(precision, scale)`, never binary floating point; currency and scale require a business decision. Quantities use an explicit numeric precision appropriate to the chosen unit model. Names and policies below are proposed logical names, not implemented migrations.

## Core entities and relationships

| Entity | Key fields and relationships |
|---|---|
| `users` | id, normalized unique login identifier, password hash, status, created/updated timestamps. Initially one owner. |
| `products` | id, unique SKU/barcode only if owner approves, name, description, unit, selling price, active flag, timestamps. Product identity and price fields need final decisions. |
| `suppliers` | id, name, contact fields, active flag, timestamps. Required fields TBD. |
| `sales` | id, unique human-readable receipt/reference, status, sold_at, created_by user, currency, totals, payment summary as approved, timestamps. |
| `sale_lines` | id, sale_id FK, product_id FK, quantity, unit price snapshot, discount/tax snapshots if approved, line total, product name/SKU snapshot. |
| `purchases` | id, supplier_id FK, external reference, status, created/received timestamps, created_by, currency and cost totals as approved. |
| `purchase_lines` | id, purchase_id FK, product_id FK, ordered/received quantity, unit cost and product snapshot. Fields depend on partial-receive decision. |
| `stock_movements` | id, product_id FK, event type, signed quantity delta, source document type/id or typed nullable FKs, occurred_at, actor, reason, idempotency/reference key. Append-only after posting. |
| `inventory_balances` (optional cache) | product_id PK/FK, on_hand quantity, updated_at, maintained in the same transaction as movements; ledger remains source of truth. |
| `audit_events` | id, actor user FK (nullable only for system event), action, entity type/id, timestamp, request/correlation ID, safe before/after metadata, reason where applicable. No secrets. |
| `sessions` (if DB-backed) | id, user_id FK, hashed token identifier, created/expires/revoked timestamps, client metadata limited to operational need. Could instead use a vetted signed-cookie/session strategy. |

Relationships: one sale has many sale lines; one purchase has many purchase lines and belongs to a supplier; each line points to a product; each stock movement points to a product and an originating business event; each audit event records an actor and target. Products can remain referenced by history after deactivation.

## Integrity and indexing

- Enforce positive line quantities for sale/receipt documents and valid nonnegative prices/costs only after policies are confirmed.
- Unique constraints for normalized login, approved SKU/barcode, and receipt reference.
- Index sales by sold_at/status/reference; line rows by sale_id; purchases by supplier/date/status; movements by product/occurred_at and source; audit by timestamp/actor/target.
- Foreign key deletion behavior should preserve history: restrict deletion of referenced products, users, suppliers, sales or purchases; prefer deactivation and retention policy.
- Use checks to prevent invalid statuses and malformed quantities. Avoid constraints that encode unresolved policies (for example, no-negative-stock) until approved.

## Stock ledger model

Every inventory change is a signed movement. Expected initial event categories are sale issue (negative), receipt (positive), and approved correction/return/reversal (sign depends on the approved workflow). Do not directly edit a balance. Corrections require an attributable actor and reason, and any approval policy remains open. A stock movement references its source document and is immutable; correction creates a compensating movement. If a cached balance is used, update it atomically with the movement and reconcile it periodically against ledger sums.

## Transaction boundaries

- **Post sale:** create sale and lines, calculate totals from server-side prices/policy, verify stock policy and availability, write stock issue movements, update balances, write audit event, commit as one transaction.
- **Post receipt:** record received quantities, create positive movements, update balances, record audit event, commit as one transaction.
- **Idempotency:** accept an idempotency key for retryable checkout/receipt posting; persist its scope and result or enforce unique source movement references to prevent duplicate posting.
- Lock affected inventory rows in deterministic product-id order, or use an equivalent concurrency-safe conditional update, to prevent simultaneous checkouts overselling. Exact shortage behavior is an owner decision.

## Decisions still required

Currency and decimal scale; units/fractional quantities; cost and valuation method; SKU/barcode constraints; sale/payment/discount/tax data model; negative-stock policy; purchase/partial receipt lifecycle; return/void/reversal representation; audit retention; session persistence; customer data fields; hard-delete and archival policy.
