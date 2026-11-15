# BMM Auto Motors application architecture

## Confirmed direction

BMM Auto Motors requires an installable application for Windows, Android, and iOS from one shared Flutter/Dart frontend codebase. The attendant primarily uses Windows at the shop; the developer tests Android first; the owner uses iPhone for remote management. Normal use requires internet. Offline synchronization is out of scope.

The existing FastAPI, PostgreSQL, SQLAlchemy, Alembic backend remains the authoritative business system. Flutter clients communicate only with authenticated FastAPI APIs over HTTPS. Clients never connect directly to PostgreSQL. The backend remains cloud hosted so every client sees the same records.

This supersedes the previous browser-first architecture. The existing HTML pages and `/demo` are legacy demonstration surfaces, not the production client architecture. Preserve the demo until a separate removal decision; do not place it inside a WebView or treat it as the application.

## Logical architecture

```text
Flutter/Dart shared application code
  |-- Windows desktop build (attendant)
  |-- Android build (developer/staging test)
  |-- iOS build (owner/TestFlight)
  |-- shared presentation, domain, API and session layers
  |-- role-aware navigation and platform adapters
        | HTTPS, JSON and authenticated API calls
        v
FastAPI modular monolith (cloud)
  |-- authentication and authorization
  |-- product/catalogue, inventory, sales, receiving, reports APIs
  |-- domain services and transactional workflows
  |-- SQLAlchemy and Alembic
        | private network, TLS
        v
PostgreSQL (single authoritative business database)
```

## Flutter application structure

Create a top-level `client/` Flutter project while keeping the Python backend in the repository. Use one application target with shared features, not three separately maintained apps. Organize by feature and shared responsibility, for example:

```text
client/lib/
  app/                 app startup, routes, role navigation
  core/                API client, errors, configuration, session
  features/
    auth/
    dashboard/
    catalogue/
    inventory/
    sales/
    receiving/
    suppliers/
    reports/
  platform/            secure storage, image picking, print adapters
```

Use responsive/adaptive layouts within shared screens: compact touch layouts on phones and keyboard/mouse-oriented wider layouts on Windows. Share domain models, validation, API repositories, and role checks. Keep Windows printing, platform secure storage, and file/image selection behind interfaces with platform implementations. Do not include business policy only in UI; the API is authoritative.

## Authentication and API transport

The existing browser authentication uses secure cookies and CSRF checks. Native Flutter routes issue short-lived opaque access tokens and rotating opaque refresh tokens. Both are high-entropy random credentials; only hashes are stored server-side. Refresh rotation locks the session row and keeps consumed token hashes to detect replay; reuse revokes that session family. Store raw tokens through platform secure storage backed by Windows Credential Manager and Android Keystore/iOS Keychain as supported by the selected maintained plugin. Never store them in preferences, source, logs, or URLs. Native secrets use headers/body over HTTPS only. Preserve existing owner accounts and browser sessions through additive migrations and validate both login paths during migration.

Authorization remains server-side. Owner and attendant capabilities must be enforced by API dependencies/services, regardless of Flutter navigation. `GET /api/v1/native/auth/me` supplies native identity and role; `GET /api/v1/auth/me` remains for browser compatibility. Role-aware menus improve usability but do not provide security. Logout revokes the server session and erases local credentials. Native refresh idle/absolute defaults are provisional and require client approval. MFA, password recovery and device recovery remain decision-register items.

All API writes use validated versioned JSON endpoints; images use bounded multipart upload with content validation. API responses should use stable error codes, pagination, and request correlation IDs. Avoid introducing a second source of business rules in client calculations. Server-calculated totals and stock transactions remain authoritative.

## Platform behavior

### Windows shop client

Optimize for desktop dimensions, keyboard navigation, barcode-compatible search if later approved, mouse, product image selection from local files, and efficient catalogue/checkout workflows. Show explicit offline/connection and server errors with retry where safe. Because offline synchronization is excluded, do not queue business writes as if successful.

Receipt printing must be evaluated after the shop provides the printer model. Recommended first compatibility path is a print-ready PDF/document sent through the installed Windows printer driver and Windows print dialog. This uses ordinary Windows printers and gives preview, but exact thermal roll sizing and cutter behavior depend on the driver. Direct ESC/POS output can be added only if the printer supports it and the model/interface are confirmed; it can enable roll/cut control but creates hardware-specific support. Confirm model, connection (USB/network/Bluetooth), driver, paper width, cutter, and whether printing must be silent/direct. Do not select or buy a printer as part of architecture work.

### Android developer test client

Android is the first installable client. Use a dedicated staging API and database with synthetic data and separate owner and attendant accounts. Build installable debug/profile artifacts for device testing; do not point the developer APK at production by default. Test login, role isolation, product registration, camera/gallery image upload, refresh, expiry, logout, network failure behavior and secure credential clearing. Use an explicit environment selector/build flavor so staging and production endpoints cannot be confused.

### iOS owner client

Keep the iOS target build-compatible in the same Flutter project. A Windows 11 development computer cannot perform the native iOS/Xcode build locally. Use a hosted macOS runner or a separately managed Mac with Xcode for signing and builds. Test on Android first; issue the owner beta through TestFlight only after staged Android testing and backend acceptance checks pass.

TestFlight requires Apple Developer Program membership for distribution (currently USD $99/year, local pricing may vary). The first external TestFlight build requires Apple beta review; builds are available for up to 90 days. The account holder should own the Apple Developer account and signing assets. Store certificates/profiles in the approved CI secret facility and restrict access. Do not commit signing keys or provisioning assets.

## Build and release strategy

1. Develop the shared Flutter code and FastAPI API locally on Windows; Windows desktop and Android builds can be made from Windows with Flutter tooling. iOS builds require macOS/Xcode.
2. Build and install Android staging artifacts on the developer's phone. Run owner and attendant flows with distinct accounts and retain test evidence.
3. Build and test the Windows package on a shop-like Windows machine, including real printer compatibility once hardware is identified.
4. Run a signed iOS staging build on hosted macOS, install internally, then submit an owner beta to TestFlight after Android and API acceptance.
5. Promote API and clients through separate staging and production configuration. Production deployment remains gated on the existing security, backup, restore and business-policy requirements.

Keep environment selection explicit and injected at build/run time. No production secrets belong in the Flutter bundle; mobile binaries are inspectable. Use TLS, short-lived/revocable credentials, least privilege, API rate limits, and server-side authorization.

## Hosted macOS options and indicative costs

Windows cannot run Xcode. Reasonable hosted options include GitHub-hosted macOS Actions runners, Codemagic hosted macOS builds, Bitrise, or an owner/developer-controlled Mac. Choose based on repository privacy, build frequency, secret controls, artifact retention, and support needs; do not purchase a plan without budget approval.

As checked 2026-11-03, published list prices include GitHub Actions macOS standard runners at USD $0.062 per minute and Codemagic macOS M2 at USD $0.095 per minute, with Codemagic listing 500 free M2 minutes/month on its free plan. Apple Developer Program membership is USD $99/year for TestFlight distribution. At 100 paid macOS runner minutes/month, illustrative compute is $6.20 on the GitHub standard macOS rate or $9.50 on Codemagic M2 after included free minutes; actual plan allowances, taxes, region, storage, and pricing can change. These figures exclude backend hosting and any optional signing hardware/service. Recheck provider prices before selection.

Reference pages: [Flutter desktop platform support](https://docs.flutter.dev/platform-integration/desktop), [Flutter iOS setup](https://docs.flutter.dev/platform-integration/ios/setup), [GitHub Actions runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing), [Codemagic pricing](https://codemagic.io/pricing/), [Apple Developer Program](https://developer.apple.com/programs/), [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/), and [Windows point-of-service printer support](https://learn.microsoft.com/en-us/windows/apps/develop/devices-sensors/pos/device-support).

## Data, failure and offline behavior

PostgreSQL remains the single source of truth. Flutter requests current data from APIs and can retain only short-lived presentation cache as needed; no local offline ledger, queued sale, or sync conflict-resolution is in scope. Clearly label connection failures and avoid showing cached data as current. Mutations use server-side transactions and idempotency where retrying could duplicate a sale or stock movement. All future sales/receiving endpoints must commit business documents and movements atomically.

## Boundaries and open decisions

This architecture confirms the clients and transport, not unapproved shop rules. Currency, tax, checkout/payment, credit, discount, returns, stock shortage, opening stock, adjustments, receipt content, report definitions, product-price precision, MFA/recovery, printer, Windows packaging/signing, hosting provider, and iOS account ownership are tracked in `client-decisions.md`. Sales and inventory behavior must not be inferred from the prior browser demo.
