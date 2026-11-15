# Spare Parts Management System

A professionally designed, installable application for BMM Auto Motors. One shared Flutter/Dart frontend will provide Windows desktop for the shop attendant, Android for developer testing, and iOS for the owner. All clients use the same cloud-hosted FastAPI service and PostgreSQL records.

## Planned technology

Flutter and Dart provide the Windows, Android and iOS application from one codebase. The retained backend uses Python, FastAPI, PostgreSQL, SQLAlchemy and Alembic, deployed in the cloud behind HTTPS. Native clients use authenticated APIs and never access PostgreSQL directly. The system is not a WebView wrapper, offline synchronization service, full accounting package, or M-PESA integration.

## Version 1 scope

Dashboard, products, inventory, sales and checkout, suppliers, purchasing and receiving, printable receipts, sales history, basic reports, authentication and audit logging.

## Project status

Current implementation includes the FastAPI foundation, owner/attendant authentication, and a database-backed product submission and approval catalogue. A shared Flutter client source foundation is in `client/`; platform runner generation, device builds and verification are pending because the current environment has no Flutter SDK or platform toolchains. Inventory, receiving, sales and checkout are not implemented. Currency, tax and later transaction policies remain open. See [Requirements](docs/requirements.md), [Architecture](docs/architecture.md), [Client decisions](docs/client-decisions.md), and [Implementation plan](docs/implementation-plan.md).

## Architecture documents

- [Requirements specification](docs/requirements.md)
- [System architecture](docs/architecture.md)
- [Database design](docs/database-design.md)
- [API contracts](docs/api-contracts.md)
- [Security plan](docs/security-plan.md)
- [Implementation plan](docs/implementation-plan.md)

## Native application delivery

The current codebase includes the FastAPI backend, legacy HTML demonstration and the initial shared Flutter source in `client/`. Android staging is the first device acceptance target; the owner iPhone beta follows through TestFlight. No business data is available offline. See [client setup](client/README.md) for requirements and build instructions. Platform runner projects and installable builds still need to be generated and verified with Flutter and platform toolchains.

Windows can build Windows and Android targets with their platform toolchains. iOS builds require macOS and Xcode, so use an approved hosted macOS runner or Mac for signing/TestFlight. Current hosted-build and Apple membership cost references are in [the architecture plan](docs/architecture.md); confirm budget and account ownership before enabling paid builds. The Windows receipt printer model is still required before direct printer integration can be selected.

## Development

Python 3.12 is the configured runtime (`pyproject.toml` requires `>=3.12,<3.13`). From the repository root, create a virtual environment and install the pinned dependencies:

```powershell
uv venv .venv-dev --python 3.12
.venv-dev\Scripts\python.exe -m pip install -r requirements.txt
Copy-Item .env.example .env
```

Set `SPARE_PARTS_DATABASE_URL` in the local `.env` to a PostgreSQL URL for your local database. Never commit `.env` or place credentials in source files. Start the development server with:

```powershell
.venv-dev\Scripts\python.exe -m uvicorn app.main:app --reload
```

The application shell is at `http://127.0.0.1:8000/`; liveness is `/health/live`, and database readiness is `/health/ready`. Apply migrations with `.venv-dev\Scripts\alembic.exe upgrade head`. Run tests with `.venv-dev\Scripts\python.exe -m pytest`.

### Initial owner account

After configuring the database and applying migrations, provision the one owner account interactively:

```powershell
.venv-dev\Scripts\python.exe -m app.auth_cli
```

The command prompts for a login name and password twice; password input is hidden and neither value is put in command-line arguments or printed. It refuses to create a second owner. Use a unique password of at least 15 characters and store it in an approved password manager. There is no self-service password reset yet; recovery requires a separately designed, authorized operator procedure. Keep `SPARE_PARTS_COOKIE_SECURE=true` and `SPARE_PARTS_NATIVE_HTTPS_REQUIRED=true` in deployments serving HTTPS. For isolated local plain-HTTP development only, the ignored `.env` may set both to `false`; never do this in production.

### Product catalogue and attendant accounts

Apply all Alembic migrations before running the app. Sign in as the owner and open `/team` to create named attendant accounts with an initial password. The owner can review submissions at `/products/approvals`; attendants can register products at `/products` and edit only their own pending submissions. Only the owner can approve/reject products or set an approved selling price. Approved items are available in the catalogue; rejected records and reasons remain stored. There is no product delete operation.

Product prices use `NUMERIC(18,4)` and are displayed without a currency symbol. Four decimal places are a provisional storage precision; the shop currency, display/rounding convention and tax policy remain unconfirmed. Product images are decoded and re-encoded as JPEG, PNG or WebP, then stored under the configured `SPARE_PARTS_PRODUCT_IMAGE_STORAGE_PATH` (default `var/product-images`) outside `app/static`. Retrieval requires an authenticated user with product visibility. This local filesystem adapter is for development only; production cloud deployment needs a private object-storage adapter, durable backups, and lifecycle/orphan-file monitoring. Pillow and python-multipart are required for image validation and bounded upload parsing.

Login throttling uses the connection peer address exposed to the ASGI app; forwarded headers are not read by application code. Behind a reverse proxy, either disable ASGI proxy-header rewriting and rely on proxy-side rate limiting, or trust forwarding data only from explicitly configured proxy addresses after the proxy strips incoming client-supplied forwarding headers. Configure edge rate limits as well, since per-peer throttling does not stop distributed attempts and can affect users sharing a proxy/NAT address. Schedule `.venv-dev\Scripts\python.exe -m app.auth_cli prune-auth-data` at least daily; it prunes expired sessions, 24-hour throttle records and the provisional 90-day authentication-event history. Throttle retention is capped at seven days and event retention at one year. Confirm retention values with the owner before production.

Authentication uses `/login`, `POST /api/v1/auth/login`, `POST /api/v1/auth/logout`, and `GET /api/v1/auth/me`. The application shell is protected. The `/demo` route remains an unauthenticated, isolated fictional demonstration and does not access business records.

## Local client demonstration

Run the existing FastAPI application, then open `http://127.0.0.1:8000/demo`. The demonstration uses fictional, in-memory browser data. Product edits, checkout previews and receiving examples reset when the page reloads; they are not saved to PostgreSQL. It does not authenticate users, record sales, process payments, or make production stock movements.

When using the WSL project environment, launch it from the project directory with:

```bash
.venv/bin/python -m uvicorn app.main:app --reload --host 0.0.0.0
```

The initial tests use in-memory SQLite and do not need PostgreSQL. To verify the configured PostgreSQL connection, start the application and request `/health/ready`; a working connection returns `{"status":"ok","database":"ok"}`. See [AGENTS.md](AGENTS.md) for project-wide development rules.
