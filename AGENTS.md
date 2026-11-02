# Project development rules

## Scope and decisions

- Follow `docs/requirements.md` and the approved Python/FastAPI/PostgreSQL/SQLAlchemy/Alembic/HTML-CSS-JavaScript/Chart.js direction.
- Preserve the single-shop, single-owner initial scope. Do not add native clients, React, accounting, M-PESA, paid APIs, or unapproved business rules.
- Treat items marked unresolved in the documents as unresolved. Ask the owner or record an explicit decision before encoding them in behavior.
- Do not deploy untested code, modify live infrastructure, or run destructive database actions without the required approval.

## Implementation quality

- Inspect the existing code, README, instructions and tests before changing anything; preserve user changes.
- Prefer small, reviewable changes and the existing project conventions. Keep business logic out of route handlers where practical.
- Use SQLAlchemy transactions and Alembic migrations for persistence changes. Never silently rewrite historical sales or stock movements.
- Validate inputs at the API boundary and enforce critical invariants in transactional application logic and database constraints where appropriate.
- Add or update tests for changed behavior and run the relevant checks. Report actual commands and results; never claim unrun checks passed.
- Keep secrets out of source control and logs. Use configuration/environment secret management appropriate to deployment.
- Update documentation when setup, behavior, security, or operational requirements change.

## Communication

- Distinguish confirmed requirements, assumptions, and open questions.
- Surface data-integrity, security, and operational risks in plain language.
- Report files changed, checks run, results, and remaining decisions.
