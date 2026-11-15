# Database design

## Conventions

PostgreSQL is authoritative. Use UUID primary keys (or another consistently chosen non-guessable key strategy), `timestamptz` in UTC, foreign keys, `NOT NULL` where meaningful, and indexes for common search/filter paths. Money uses `numeric(precision, scale)`, never binary floating point; currency remains a business decision. Quantities use an explicit numeric precision appropriate to the chosen unit model. Authentication and product catalogue tables are implemented by migrations through `0007`.

## Core entities and relationships

| Entity | Key fields and relationships |
|---|---|
| `users` | id, globally unique normalized login identifier, password hash, `owner`/`attendant` role, active status, created timestamp. Migration `0004` copies the existing owner and backfills user IDs into sessions/audit events without rotating existing session tokens. The original `owner_accounts` rows and legacy FK columns remain for compatibility and history. |
| `auth_sessions` | Existing browser-cookie sessions. Stores only token and CSRF hashes, user/legacy owner references, activity/idle/absolute expiry and revocation. Existing owner browser sessions are preserved by migration `0004`. |
| `native_auth_sessions` | Native Flutter session with user FK, current access-token hash, access expiry, last refresh, idle/absolute expiry and revocation. One session represents one revocable token family. |
| `native_refresh_tokens` | Hashed refresh-token history for a native session. `consumed_at` and replacement hash record rotation/replay history; a partial unique index allows at most one unconsumed refresh token per session. Rows are retained until their session expires/revokes and is pruned. |
| `auth_events` | Minimal safe auth/account audit events, including native login, refresh-token reuse and logout. Passwords, access/refresh tokens and their hashes are never recorded. |
| `products` | UUID id, unique generated internal reference, name, optional description/category/manufacturer part number/image key, `NUMERIC(18,4)` selling price, approval status, submitting/approving users and timestamps, rejection reason. Names and manufacturer part numbers are not unique. |
| `product_events` | Append-only application events for submission, edit, approval, rejection and image update, with actor and timestamp. |
| `suppliers` | id, name, contact fields, active flag, timestamps. Required fields TBD. |
| `sales` | `id`, unique `receipt_number`, unique `idempotency_key`, `request_hash`, `status`, `total_amount` (`NUMERIC(18,4)`), `payment_method` (`cash` or `mpesa`), `amount_tendered`, `change_given`, optional `payment_reference`/`notes`, `sold_by` FK, `sold_at`. |
| `sale_lines` | `id`, `sale_id` FK, `line_number`, `product_id` FK, immutable product snapshots (`product_internal_reference`, `product_name`, `product_description`, `manufacturer_part_number`), `unit_price` (`NUMERIC(18,4)`), `quantity` (`NUMERIC(18,4)`), `line_total` (`NUMERIC(18,4)`). |
| `purchases` | id, supplier_id FK, external reference, status, created/received timestamps, created_by, currency and cost totals as approved. |
| `purchase_lines` | id, purchase_id FK, product_id FK, ordered/received quantity, unit cost and product snapshot. Fields depend on partial-receive decision. |
| `stock_movements` | id, product_id FK, event type, signed quantity delta, source document type/id or typed nullable FKs, occurred_at, actor, reason, idempotency/reference key. Append-only after posting. |
| `inventory_balances` (optional cache) | product_id PK/FK, on_hand quantity, updated_at, maintained in the same transaction as movements; ledger remains source of truth. |
| `audit_events` | id, actor user FK (nullable only for system event), action, entity type/id, timestamp, request/correlation ID, safe before/after metadata, reason where applicable. No secrets. |
| `sessions` (future business sessions) | Do not add a second session mechanism; use the implemented `auth_sessions` for browser cookies and `native_auth_sessions` / `native_refresh_tokens` for Flutter clients. |

Relationships: one sale has many sale lines; one purchase has many purchase lines and belongs to a supplier; each line points to a product; each stock movement points to a product and an originating business event; each audit event records an actor and target. Products can remain referenced by history after deactivation.

## Integrity and indexing

- Enforce positive line quantities for sale/receipt documents and valid nonnegative prices/costs only after policies are confirmed.
- Unique constraints for normalized login and generated product reference. No uniqueness constraint exists on product name or manufacturer part number.
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

## Authentication migration downgrade and recovery policy

Authentication downgrade commands are guarded against discarding records that the prior schema cannot represent. A refused downgrade leaves the migration revision and data unchanged. Do not use a production downgrade as a substitute for a tested backup restoration; take and verify a backup before any migration release, and prefer a forward corrective migration when newer-schema records already exist.

Other revisions in the current chain are not universally reversible with data: `0002_owner_authentication` drops its authentication tables on downgrade, `0003_client_login_throttling` cannot restore throttle rows removed when its upgrade changed throttle-key meaning, and `0005_product_catalogue` drops products and product-event history on downgrade. Treat those downgrades as destructive and restore a verified backup if their data must be retained.

| Migration | Downgrade policy |
|---|---|
| `0004_named_user_roles` | Reversible only while `users` contains owner identities that exactly match `owner_accounts`, all browser sessions map to the legacy owner ID, and audit actors map to the legacy owner. The downgrade refuses attendant accounts, attendant sessions, unrepresentable actor references, or changed/missing owner identity records. Preserve the database and use a forward correction or restore a verified pre-migration backup. |
| `0006_attendant_auth_events` | Reversible only if there are no `attendant_created` or `attendant_status_changed` audit rows. It refuses before changing the check constraint when such audit history exists. Keep the audit rows and use a forward correction or restore a verified backup. |
| `0007_native_auth_sessions` | Reversible only if there are no native sessions, refresh-token history, or native-authentication audit rows. It refuses before changing constraints or dropping native tables when any such rows exist. Keep session/audit data and use a forward correction or restore a verified backup. |

PostgreSQL integration tests cover safe downgrades and refusal with preserved attendant-session and authentication-event records. These checks reduce accidental loss; they do not replace backup-and-restore rehearsal or release approval.
