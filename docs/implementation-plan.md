# Implementation plan

Milestones are sequenced so each can be reviewed and tested independently. Do not start a milestone that depends on an unresolved business rule until the owner decides it. No code, package installation, or deployment was performed as part of this architecture assignment.

## Before implementation: decisions and setup

1. Resolve requirements marked as blocking in `requirements.md`: currency/tax/receipt rules; product identity and units; payment, pricing, returns/voids and stock shortage policy; purchasing/receiving lifecycle; adjustment controls; owner account recovery; reports; deployment and recovery objectives.
2. Confirm cloud provider/region/domain/budget, environment ownership, staging approach, and who can access production.
3. Create repository conventions, Python runtime target, dependency policy, local development instructions, and CI checks. Validate that runtime tooling is actually available before selecting versions.

## Milestones

| # | Milestone | Independently verifiable outcome |
|---|---|---|
| 1 | Application foundation | FastAPI app, configuration, structured safe logging, health checks, SQLAlchemy session setup, PostgreSQL local/dev configuration, Alembic baseline. Unit/integration checks for startup and database connectivity. |
| 2 | Authentication and audit base | One-time owner bootstrap, secure login/logout/session handling, authorization dependency, audit event service. Checks for unauthenticated denial, session behavior, and audit recording. |
| 3 | Products and suppliers | CRUD/search/deactivation with validation and history-safe behavior. API and UI checks on desktop/mobile layouts. |
| 4 | Inventory ledger | Movement model, balance strategy/reconciliation, controlled correction flow after approval. Tests for atomic movement, permissions, and concurrent balance behavior. |
| 5 | Purchasing and receiving | Draft/approved purchase workflow as decided; receipt posting creates ledger movement atomically and retries do not duplicate. |
| 6 | Sales and checkout | Server-calculated pricing and totals, transactional stock issue, idempotency, approved payment and correction lifecycle. Test rollback, duplicate retry and concurrent checkout behavior. |
| 7 | Receipts and sales history | Search/filter, immutable receipt view with print stylesheet and approved receipt content. Verify history and browser print layout. |
| 8 | Dashboard and reports | Approved metrics, date ranges and inventory/sales reports; validate aggregation against known fixtures and responsive charts. |
| 9 | Hardening and release readiness | Security review, accessibility/usability pass, dependency review, backup restore drill, migration/release rehearsal, production runbook, tested staging release. No deployment until code and procedures pass agreed checks and owner approves. |

## Verification policy

For each milestone, add focused unit tests for domain rules, API integration tests against PostgreSQL where database semantics matter, and UI checks for key browser workflows. Include regression coverage for stock ledger invariants, transaction rollback, idempotency, permissions and audit. Run tests, formatting/type/lint checks selected by the project, inspect actual output, and review migrations/diffs before merging. This assignment added documents only; no software tests were applicable or run.

## Dependencies and gates

- Sales and receiving depend on the stock ledger and approved lifecycle rules.
- Dashboard/report definitions depend on agreed business meanings, currency, timezone and status semantics.
- Production launch depends on TLS/domain, managed PostgreSQL, secrets, monitoring, backup/restore verification, access policy and release runbook.
- Any M-PESA work, accounting capability, additional roles, multi-shop tenancy, offline mode or native application requires separate approval and scope review.
