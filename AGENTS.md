# Project development rules

## Scope and decisions

- Follow `docs/requirements.md` and the approved shared Flutter/Dart application plus Python/FastAPI/PostgreSQL/SQLAlchemy/Alembic backend direction.
- Build one Flutter application for Windows, Android, and iOS. Do not create independent frontends, a WebView substitute, a React client, or direct database connections from clients.
- Preserve the single-shop business scope and confirmed owner/attendant roles. Do not add accounting, M-PESA, offline synchronization, paid services, or unapproved business rules.
- Keep browser templates and `/demo` distinct from the production Flutter clients. Flutter communicates through authenticated FastAPI APIs only.
- Test Android staging before owner TestFlight distribution. Windows changes must retain keyboard/mouse support and consider printer compatibility without assuming a printer model.
- iOS builds require macOS and Xcode; use an approved hosted macOS runner or Mac and never commit signing secrets.
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
