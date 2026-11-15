# Implementation plan

This plan implements the confirmed Windows, Android, and iOS Flutter clients around the existing FastAPI/PostgreSQL backend. The delivery remains gated by business rules listed in `client-decisions.md`. Do not implement sales, stock, tax, or payment behavior from the fictional browser demo.

## Decisions and readiness gates

Resolve or explicitly defer before the dependent work: native API session transport/expiry; app environment and account ownership; printer model and receipt format; Windows installation/signing method; Apple Developer account and hosted macOS budget; currency/tax/payment/discount/credit/returns; stock shortage/opening balance/adjustment; dashboard definitions; backups and operational ownership. Decisions on platform hosting can proceed in parallel with backend feature work.

## Milestones

| # | Milestone | Independently verifiable outcome |
|---|---|---|
| 1 | API hardening for native clients | Add additive native session API using opaque revocable credentials, secure expiry and logout. Preserve owner rows and browser sessions. Test Android/Windows/iOS bearer authorization, session rotation/revocation, rate limiting and role authorization. |
| 2 | Shared Flutter skeleton | Add one `client/` Flutter/Dart project with shared API, error, session and role navigation layers and Windows/Android/iOS targets. Validate Android and Windows builds, API environment separation, keyboard/touch navigation and no offline write queue. |
| 3 | Android staging client | Produce installable staging APK/AAB according to test purpose. Test separate owner/attendant accounts, login, product registration, image picking/upload, refresh, expiry, logout, lost connectivity and server errors. Attach test evidence before owner beta work. |
| 4 | Windows attendant application | Build installable Windows package with desktop catalogue/search, role-safe workflows, file image selection, keyboard/mouse support, connection handling and chosen distribution/update approach. Test printing only after printer model/interface is identified. |
| 5 | iOS owner application | Use macOS/Xcode local or hosted runner to build/sign the shared Flutter target. Test owner dashboard, approvals/price setting, photo viewing, remote API access, secure storage and logout on iPhone. Submit to TestFlight after Android staging acceptance. |
| 6 | Inventory ledger | After opening stock, adjustments, units and negative-stock decisions, implement ledger and balances. Test atomic writes, role policy, concurrency and reconciliation. |
| 7 | Purchasing and receiving | After purchase lifecycle and supplier fields are confirmed, implement receiving with atomic stock movements and retry protection. |
| 8 | Sales and checkout | After currency, tax, tender, credit, discounts, returns and shortage policy are decided, implement server-priced checkout and atomic stock issue. Test rollback, duplicates, concurrency, permission enforcement and audit. |
| 9 | Receipts, history and reporting | Implement approved receipt content, printing path, history, date filters, metrics and exports. Verify against agreed fixtures and Windows printer. |
| 10 | Production readiness | Security review, app signing/release process, dependency checks, monitoring, backup restore, migration rehearsal, staging acceptance and support runbook. Production release requires client approval. |

## Test and release workflow

- Keep development, staging and production API/database credentials separate. Staging contains synthetic data only.
- Test in this order: API contract and authorization tests; Android developer staging; Windows shop-like environment; iOS staging/TestFlight beta.
- Android/iOS are real installable app builds. No WebView wrapper and no production use of the unauthenticated fictional `/demo`.
- Pin Flutter SDK and Dart constraints, dependencies and build toolchain once the Flutter project is initialized. Run formatting, static analysis, unit/widget tests, API integration tests, and platform build checks in CI.
- Windows and Android artifacts can be built on Windows with their platform toolchains. iOS simulator/device archives require macOS and Xcode; configure a hosted macOS workflow and protected signing secrets.
- Promote versioned client builds and API releases only after staging checks. Never put API secrets or signing keys in client source or binaries.

## Cost and operations checkpoint

Before enabling hosted macOS builds, compare current provider prices, free allowances, artifact retention and secret controls. As of 2026-11-03, see the current indicative USD prices in `architecture.md`; Apple Developer membership for TestFlight is currently USD $99/year. Confirm the account owner, budget and permitted billing method first. Windows code-signing certificate, managed backend/database, storage, backups, monitoring, and printer hardware costs remain separate and unpriced.
