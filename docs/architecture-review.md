# Architecture and readiness review

> Historical review from the browser-application phase. The later BMM Auto Motors platform decision replaces its browser-only architecture findings. The current approved target is one Flutter application for Windows, Android and iOS over the FastAPI API; see `architecture.md` and `requirements.md`.

## Scope reviewed

Reviewed all eight project documents: `AGENTS.md`, `README.md`, and the six documents under `docs/` present before this review (`requirements.md`, `architecture.md`, `database-design.md`, `api-contracts.md`, `security-plan.md`, `implementation-plan.md`). No application code was reviewed because none exists.

## Findings by severity

### Contradictions and inconsistencies

- No direct conflict was found between the approved stack, single-shop/owner scope, and browser-based architecture.
- The wording “one owner account initially” is sometimes treated as a firm single-user v1 and elsewhere leaves future employees/concurrent sessions open. Clarify that one owner is confirmed for the initial launch; additional roles are out of current scope until approved. No plan amendment is necessary because the documents label this as open.
- Architecture/database documents recommend secure cookie sessions but permit signed-cookie sessions. A purely stateless signed cookie cannot immediately revoke a stolen session, while the security plan expects revocation. Select server-side revocable sessions (or an explicitly designed revocation mechanism) before production. This is a missing technical decision, not an existing conflicting requirement.
- The API proposes `POST /sales` to create/post a sale, while the request notes draft/post may be separate. This is intentionally unresolved but means the endpoint list is illustrative, not an implementable contract yet.
- Database and API documents mention returns, reversals, corrections, partial receipts, customer fields, and payment fields as possibilities. These are not contradictory, but must remain conditional until the owner chooses scope and rules.

### Missing requirements and technical decisions

- No acceptance criteria or concrete success/error behavior for checkout, receive, or adjustment have been approved.
- No defined currency, tax, tender, credit, discount, refund, exchange, stock shortage, opening balance, or purchase lifecycle policies (see `client-decisions.md`).
- No initial data migration/import, product catalog bootstrap, opening count, or cutover/reconciliation plan is defined.
- No selected Python version, dependency/package manager, app server, template engine, session implementation, CI runner, or supported browser matrix.
- No concrete request timeout/rate limits, connection pool sizing, pagination limit, idempotency retention/scope, or concurrency strategy acceptance criteria.
- Backup mention lacks frequency, retention, encryption configuration, RPO/RTO and proof of restore. Region/data residency and incident response owner are also open.
- Audit event schema and append-only guarantee are described logically only. Database privileges/triggers, event schema versioning, tamper resistance, retention and safe metadata size/contents need design.
- Receipt browser printing is a reasonable baseline, but layout width, browser/device behavior, paper/printer and legal content are unknown.
- No accessibility, language, data privacy, retention, or support expectations have been approved.

### Unnecessary complexity or premature detail

- A dedicated `inventory_balances` cache is optional; ledger sum can be authoritative initially. Avoid introducing balance-cache reconciliation complexity until measured query needs justify it. If a cache is chosen, transactional update and reconciliation are mandatory.
- The entity design allows polymorphic stock source IDs, multiple session strategies, multiple pagination strategies, and tentative purchase statuses before the lifecycle is known. These are alternatives, not simultaneous requirements. Pick one minimal implementation after relevant decisions.
- A full API route inventory and example payment payload containing placeholder values can be mistaken for an approved contract. The API document correctly warns this is illustrative; keep that warning prominent and remove placeholders when contract work starts.
- Audit “before/after metadata” could expand into broad data duplication. Capture only the minimum safe fields needed for accountability; do not log full request bodies.

## Technical readiness

| Capability | Assessment | Remaining design / acceptance work |
|---|---|---|
| Concurrent computer and phone access | Supported by one cloud web app and centralized PostgreSQL; both clients share records. No offline mode is promised. | Confirm concurrent sessions; choose deployment capacity, request behavior on stale pages, and operational availability. |
| Atomic sale and inventory transactions | Supported conceptually by a service-layer transaction combining sale, lines, movements, balance and audit. | Implement row locking/conditional update, deterministic lock ordering, retry/idempotency behavior and rollback tests. Confirm shortage and pricing policy. |
| Append-only stock movements | Supported as an application-level model with compensating events. Not yet guaranteed against privileged SQL edits or application defects. | Restrict DB role update/delete permissions; consider database triggers/partitioning only if requirements justify them; define correction source/reason, audit linkage and reconciliation. Test that posted movements cannot be mutated through normal APIs. |
| Historical sales retrieval | Supported by sales/line tables, product snapshots, status and date/reference indexes; product deactivation preserves links. | Snapshot all receipt-critical values (name, identifier, unit, price, tax/discount, currency, totals and payment detail as approved). Define timezone and correction/return display. |
| Receipt printing | Browser-rendered HTML and print CSS are suitable for basic print output. | Confirm required text, tax/legal details, language, paper size, supported browsers/printer and reprint behavior. Browser print is not guaranteed to drive a specific thermal printer silently. |
| Secure authentication | Plan includes password hashes, one-time bootstrap, secure cookies, CSRF, rate limits and server-side authorization. Suitable baseline for a small app. | Choose revocable session design and lifetimes, password recovery/MFA, CSRF implementation, bootstrap protection, TLS termination/proxy trust and role model. Test authorization on every route. |
| Backups and restoration | Architecture calls for scheduled backups and a tested restore procedure. | Not production-ready until provider, schedule, retention, encryption, independent restore test, RPO/RTO, alerting and named operator are decided. Backups are not proven by configuration alone. |
| Cloud deployment | Logical topology is appropriate: app service plus private managed PostgreSQL, HTTPS, secrets, staging. | Provider/region/domain/cost, app runtime, deployment pipeline, secrets, database TLS/network, migration rollout, health checks, observability and recovery targets remain unspecified. |

## Risks

1. **Policy uncertainty can corrupt historical meaning.** Tax, payment, price snapshots, returns and stock shortage rules shape irreversible posted records. Do not build/post transactions until their dependent rules are decided.
2. **Concurrency can oversell without correct database semantics.** A UI-level stock check is insufficient; transaction isolation/locking and retry behavior need PostgreSQL integration tests.
3. **Ledger append-only is not automatic.** ORM convention alone cannot prevent mutation or direct database edits. Privileges and operational access must match the integrity claim.
4. **Receipt expectations may include local compliance.** The specification must be validated by the owner and appropriate local adviser; current task does not define legal receipt requirements.
5. **Internet dependency and recovery are material operational risks.** No offline mode is planned, and service outage/recovery targets are undecided.
6. **No version control is initialized.** Changes lack Git diff/history/rollback until repository initialization; establish the repository before code work.
7. **Runtime is unverified.** Python launchers are present as Windows app aliases but fail to execute, so development compatibility and target Python version have not been established.

## Environment readiness check

Checked in `C:\Users\DELL\Developer\spare-parts-system` without installing packages or changing environment state:

- Project directory exists and contains the planning files.
- Git executable: `C:\Program Files\Git\cmd\git.exe`; `git --version` returned `git version 2.55.0.windows.5`.
- Git is **not initialized** here: `.git` is absent; an earlier `git status` returned “not a git repository”.
- `python` and `py` resolve to WindowsApps aliases, but both fail to execute (“file cannot be accessed by the system”). Python availability/version is therefore **not verified**. No alternate runtime was confirmed.
- No packages were installed, no infrastructure was modified, and no code or tests were run.

## Implementation readiness recommendation

**Do not begin transaction-heavy feature implementation yet.** The client should decide D-01 through D-12 (or explicitly defer corresponding features) before schemas and checkout/receiving behavior are committed. A narrow, reversible repository/toolchain setup and non-business application skeleton could follow, but first initialize version control and make a working Python runtime available; neither action was performed in this review. Production deployment is not ready until D-19 through D-25 and the operational controls above are settled and tested.

The existing implementation plan does not contain a genuine inconsistency requiring edits. It already places policy resolution before dependent workflows and release hardening before deployment. This review adds detail to its decision gates rather than changing the sequence.
