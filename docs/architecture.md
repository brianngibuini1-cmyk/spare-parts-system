# System architecture

## Goals and boundaries

One shop, one initial owner, one responsive web application, and one centralized database. Desktop and phone browsers use the same HTTPS application. Version 1 covers the capabilities listed in `requirements.md`. It excludes native clients, accounting, M-PESA, and unapproved business policy.

## Environment inspection

At planning time the project directory was empty: no README, source, tests, or project instructions existed before these documents were added. The directory is not a Git repository. Git 2.55.0 is available. The `python` and `py` Windows app execution aliases are present but could not run in this environment, so no Python runtime version was verified. No packages were installed and no application or infrastructure was created.

## Logical architecture

```text
Desktop or mobile browser
        | HTTPS (HTML pages, CSS/JS, JSON API)
        v
FastAPI application (cloud-hosted)
  |-- authentication/session and authorization
  |-- HTML page routes and static assets
  |-- versioned API routes
  |-- service layer: sales, receiving, inventory, reporting
  |-- SQLAlchemy data access and Alembic migrations
        | TLS database connection, private network
        v
Managed PostgreSQL (authoritative business records)
```

Keep a modular monolith initially. It has fewer operational parts and allows each workflow to use database transactions. Separate modules internally; split services only if future scale or operational needs justify it. Do not expose PostgreSQL publicly.

## Request and transaction flow

1. Browser sends HTTPS request with secure session cookie and CSRF token for state-changing browser requests.
2. FastAPI validates input, authenticates the owner, authorizes the operation, and invokes a domain service.
3. Domain service opens a SQLAlchemy transaction, locks/validates affected stock rows or balance records, writes the business document, its lines, stock movements, and audit event atomically.
4. Commit succeeds before the application returns a success response or printable receipt view. Failure rolls back all related records.

Use server-rendered pages or lightweight HTML templates with JavaScript enhancement; API and page behavior should share services. Chart.js consumes aggregated report data, not raw database access. Avoid frontend framework dependencies.

## Operational design

- Configuration is environment-specific; secrets come from the cloud provider's secret store.
- Apply reviewed Alembic migrations as a release step with backup and rollback planning. Do not rely on app startup to make unreviewed schema changes.
- Structured logs omit passwords, session tokens and unnecessary personal data. Capture request IDs and operational errors.
- Provide health/readiness checks, error monitoring, database connection limits, scheduled backups, and a tested restore procedure before production use.
- Use staging with a separate database and non-production credentials. Promote only reviewed, tested artifacts.

## Key architecture decisions and caveats

- **Confirmed:** FastAPI/Python/PostgreSQL/SQLAlchemy/Alembic and browser UI direction.
- **Recommendation:** modular monolith, server-side rendered HTML, same-origin JSON endpoints, secure cookie sessions, PostgreSQL ledger-backed stock.
- **Open:** cloud provider/region, runtime and hosting topology, static asset/CDN approach, email/SMS provider for resets, availability and recovery targets. Do not choose paid services until budget/owner approval.
- A single application instance is conceptually enough at first, but production must account for provider availability, backups and deployments. No offline operation is promised; internet access is a stated prerequisite.
