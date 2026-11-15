# BMM Auto Motors Flutter client

This directory contains the shared Flutter/Dart source for the Android, Windows and iOS application. It uses Material 3 and the existing FastAPI service; there is no WebView or direct database connection.

## Requirements

- Flutter stable SDK with Dart 3.4 or newer.
- Android development: Android SDK, Android Studio command-line tools, and a connected device or emulator. Android device testing must use a reachable HTTPS staging API, not `localhost` on the Windows computer.
- Windows desktop builds: Windows 10/11 with Visual Studio 2022, the **Desktop development with C++** workload, and its C++ ATL components (required by the secure-storage plugin).
- iOS builds: macOS with Xcode and CocoaPods. Configure the secure-storage Keychain entitlement in the iOS runner as required by its plugin documentation. Windows cannot build or sign iOS applications. Distribution to the owner's beta requires Apple signing configuration and TestFlight/App Store Connect access.

## First-time setup

From the repository root, generate platform runners in a separate temporary Flutter project so the existing client sources are not overwritten:

```powershell
flutter create --platforms=android,windows,ios --project-name bmm_auto_motors client_platform_seed
```

Merge the generated `android/`, `windows/`, `ios/` runner directories and required platform metadata into `client/`; keep this client's `lib/`, `test/`, `pubspec.yaml` and analysis options. Remove the temporary seed after checking the merged runner configuration. Then install dependencies from `client/`:

```powershell
Set-Location client
flutter pub get
```

`flutter_secure_storage` is the only runtime package. It stores the token record using each platform plugin's protected storage. The client does not store passwords. Platform integrations still need validation on their target operating systems.

## Configure and run

Provide the HTTPS API base URL at build/run time. No endpoint or credential is embedded in the source:

```powershell
flutter run -d <device-id> --dart-define=API_BASE_URL=https://your-staging-api.example --dart-define=APP_ENV=staging
```

Supported build-time `--dart-define` options:
- `API_BASE_URL` (required): HTTPS API origin (e.g. `https://staging.example.test`). Must use HTTPS in staging and production.
- `APP_ENV` (optional, default `staging`): `development` (`dev`), `staging` (`stage`), or `production` (`prod`). Non-production builds display a visible top-corner banner (`STAGING` or `DEV`) to prevent mistaking test builds for the live shop system. Release builds forbid `development`.
- `ALLOW_INSECURE_DEV_HTTP` (optional, default `false`): Development-only opt-in allowing cleartext HTTP on local loopback. Strictly forbidden in release builds.
- `ANDROID_ADB_REVERSE` (optional, default `false`): Development-only opt-in allowing a physical Android device connected via USB to reach the workstation through `adb reverse tcp:8000 tcp:8000` over `http://127.0.0.1:8000`. Strictly forbidden in release builds and non-Android targets.
- `SPARE_PARTS_PRODUCT_IMAGE_MAX_BYTES` / `PRODUCT_IMAGE_MAX_BYTES`: Match backend upload limits (default `5242880` bytes = 5 MiB, maximum `20971520` bytes = 20 MiB).

The app fails closed if `API_BASE_URL` is absent or is not HTTPS. API authentication uses the native routes documented in `../docs/api-contracts.md`. Login and refresh tokens are stored together in platform secure storage; the authenticated role is always re-read from `/api/v1/native/auth/me`.

## Checks and builds

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test --reporter expanded

# Android release APK:
flutter build apk --release --dart-define=API_BASE_URL=https://your-staging-api.example --dart-define=APP_ENV=staging

# Windows desktop release executable:
flutter build windows --release --dart-define=API_BASE_URL=https://your-staging-api.example --dart-define=APP_ENV=staging
```

The release APK is created at:
`build/app/outputs/flutter-apk/app-release.apk`

Install it on an attached Android device with:

```powershell
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

### Android release signing

Release builds check for `android/key.properties` (git-ignored, along with `*.jks`/`*.keystore`). Expected keys:
```properties
storeFile=path/to/keystore.jks
storePassword=your-store-password
keyAlias=your-key-alias
keyPassword=your-key-password
```
If `key.properties` is absent, the release build falls back to signing with the local debug key and logs a warning. This is suitable for internal device testing but cannot be updated to production.

### Windows desktop build prerequisites

Building Windows desktop binaries requires:
1. Windows 10/11 with **Developer Mode enabled** (`ms-settings:developers`) to allow symlink creation for plugin assets.
2. Visual Studio 2022 with the **Desktop development with C++** workload installed, including MSVC v143, Windows SDK, and C++ ATL.
Output is placed under `build/windows/runner/Release/` with executable `bmm_auto_motors.exe`.

### Attendant catalogue workflow (`SHOP_ATTENDANT`)

- **Navigation**: `Products` (`CatalogueSection.browse`) and `Product registration` (`CatalogueSection.register`) in `AppShell`.
- **Capabilities**:
  - Browse and search visible products (`GET /api/v1/products?limit=50&q=...&approval_status=pending|approved|rejected`).
  - Open product detail (`GET /api/v1/products/{id}`) and view authenticated product photographs (`GET /api/v1/products/{id}/image`).
  - Submit new products for owner approval (`POST /api/v1/products`) with optional photograph upload (`POST /api/v1/products/{id}/image`).
  - Edit product fields (`PATCH /api/v1/products/{id}`) and upload/replace photographs (`POST /api/v1/products/{id}/image`) **only** on the attendant's own pending submissions (`product.can_edit == true`).
  - Approved, rejected, and other users' products are read-only. Owner approval and rejection controls are never exposed to attendants.

### Owner product review and approval workflow (`OWNER`)

- **Navigation**: `Product approvals` (`CatalogueSection.approvals`) and `Products` (`CatalogueSection.browse`) in `AppShell`.
- **Review queue (`Product approvals`)**:
  - Defaults to filtering by `approval_status=pending` (`GET /api/v1/products?limit=50&approval_status=pending`) so products awaiting owner review are presented immediately.
  - Supports switching status filters (`Pending approval`, `Approved`, `Rejected`, `All visible`) and searching by keyword (`q` across name, internal reference, category, and manufacturer part number).
  - Handles empty pending queues (`No pending products awaiting review.`) without displaying an error state.
- **API endpoints and payloads**:
  - `GET /api/v1/products` (with `limit`, optional `q`, and optional `approval_status`) and `GET /api/v1/products/pending`.
  - `GET /api/v1/products/{id}` and `GET /api/v1/products/{id}/image`.
  - **Approve product**: `POST /api/v1/products/{id}/approve` with JSON body `{"selling_price": "<decimal-string>"}`.
    - Client and backend validation require a non-negative finite decimal (`>= 0`, `<= 99999999999999.9999`, at most 4 decimal places).
    - Permitted by the backend for `pending` products (initial approval) and `approved` products (updating the approved selling price); rejected (`409`) for `rejected` products.
    - Prices are displayed using the exact server decimal representation without a fabricated currency symbol because currency and tax semantics are not yet finalized.
  - **Reject product**: `POST /api/v1/products/{id}/reject` with JSON body `{"reason": "<trimmed-string>"}`.
    - Client and backend validation require a non-empty reason between 1 and 2,000 characters after trimming.
    - Permitted by the backend only for `pending` products (`409` otherwise).
    - Once rejected, a product is locked (`can_edit == false`) and cannot be edited, receive photograph updates, or be approved later.
- **Duplicate submission and session safety**:
  - While an approval or rejection request is in flight (`isReviewActionInProgress`), both the approve and reject actions are disabled to prevent duplicate submissions.
  - After a successful approval or rejection, the detail view updates with the returned `ProductItem` and the underlying review list is refreshed automatically.
  - Any `401` response after single-flight token refresh transitions the application back to `LoginScreen` via `AuthController.handleSessionExpired`.

### Known limitations and open client decisions

- **Image file selection**: Because `pubspec.yaml` intentionally avoids unverified third-party file-picker plugins in this environment, local image selection uses `showLocalFileImagePickerDialog` (`dart:io` `File` path entry). On Android devices, shared-storage access via raw paths is subject to Android scoped-storage rules until a platform file-picker channel or approved plugin is added.
- **Unresolved business decisions (preserved without assumptions)**:
  - Currency symbol/code and tax semantics for `selling_price` (`NUMERIC(18,4)`).
  - Whether rejected products should ever support an explicit resubmission workflow in a future milestone.
  - Cursor/offset pagination beyond the `limit` (`1..100`) parameter on `GET /api/v1/products`.

## iOS and TestFlight

On a Mac, install Xcode, accept its license, install the iOS platform components, and configure an Apple Developer signing team and bundle identifier. Then run `flutter pub get`, `flutter build ios --release --dart-define=API_BASE_URL=https://your-staging-api.example`, archive/sign with Xcode, and upload the archive to App Store Connect for TestFlight processing. Apple Developer Program enrollment and hosted macOS build services may have costs; confirm account ownership and budget before enabling either. Windows cannot verify an iOS build.

## Structure

- `lib/app/`: Material theme and application root.
- `lib/core/`: HTTPS configuration, API transport, safe errors and credential storage.
- `lib/features/authentication/`: native login and session controller/repository.
- `lib/features/catalogue/`: attendant product catalogue and owner product review/approval models, repository, controller, image picker, and screens.
- `lib/features/navigation/`: owner/attendant application shells.
- `test/`: unit and widget tests for transport, configuration, authentication, navigation, attendant catalogue, and owner review workflows.
