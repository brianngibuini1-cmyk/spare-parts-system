# Security plan

## Threat-aware baseline

The system is internet-accessible and holds business and authentication data. The initial account is an owner, but that does not remove risks from stolen credentials, cross-site requests, injection, accidental data exposure, compromised dependencies, or lost backups.

## Identity and sessions

- Store only a modern, salted, deliberately slow password hash using a maintained password hashing library; never plaintext or reversible passwords.
- Bootstrap the first owner through a controlled one-time setup mechanism; do not ship a known default password. Disable setup after completion.
- The initial owner authentication stores a salted password hash and opaque random session tokens as SHA-256 digests in PostgreSQL. Login issues a new session; logout revokes it. Session cookies are `Secure` by default, `HttpOnly`, `SameSite=Lax`, and path scoped; the separate CSRF cookie is `Secure`, readable by same-origin JavaScript, and `SameSite=Strict`. Cookie-authenticated logout requires both the CSRF cookie and matching header token plus a same-origin login request.
- Current provisional session limits are 30 minutes idle and 12 hours absolute, configurable through `SPARE_PARTS_SESSION_IDLE_SECONDS` and `SPARE_PARTS_SESSION_ABSOLUTE_SECONDS`. Failed logins are throttled by the ASGI-observed client peer address (5 failures per 15-minute window, then a 15-minute source lockout by default); account names are not locked. The application does not read `X-Forwarded-For` or another forwarding header directly. Confirm operational timeout and recovery expectations before production.
- Login throttle rows are retained for 24 hours (maximum 7 days) and authentication audit events for 90 days (maximum 365 days) by default. These are provisional operational retention values pending owner confirmation. Pruning occurs during login and through `python -m app.auth_cli prune-auth-data`; production must schedule the command at least daily. Client-address digests are pseudonymous, not anonymous, because IP addresses have a small enumerable space.
- Individual failed-login attempts are not written as audit rows; one `login_limited` event is recorded when a peer first reaches its threshold. This bounds event creation per peer/window while preserving successful-login, logout, provisioning, and limit events.
- Session activity is persisted no more than once per configured 60-second interval. Idle and absolute expiry are still checked against database timestamps on each authenticated request; a quiet session can expire up to one write interval earlier than its most recent request.
- Owner password provisioning is an interactive one-time CLI command after migrations; it has no default credential and refuses a second owner. Passwords require 15 characters minimum, have no composition rule, and are not logged. Recovery still requires an authorized operator procedure.
- Protect login/reset endpoints with rate limiting and generic responses. Password reset channel, MFA, and recovery process require a decision.
- Do not place bearer credentials in URLs or browser local storage.
- Native Flutter clients use short-lived opaque access tokens and rotating opaque refresh tokens alongside the existing cookie/CSRF browser session. Tokens are high-entropy random credentials; only hashes are stored in PostgreSQL. Refresh rotation is protected by a session row lock and unique active-refresh constraint. Reuse of a consumed token revokes the session family and records an audit event. Provisional defaults are 10-minute access, 30-minute idle from refresh, and 12-hour absolute session expiry; configure through `SPARE_PARTS_NATIVE_ACCESS_TOKEN_SECONDS`, `SPARE_PARTS_NATIVE_SESSION_IDLE_SECONDS`, and `SPARE_PARTS_NATIVE_SESSION_ABSOLUTE_SECONDS`. These require client approval before production. Store raw credentials through OS secure storage backed by Windows Credential Manager, Android Keystore, and iOS Keychain as supported. Never store them in ordinary preferences or logs. Logout revokes the server record and clears device storage.
- Treat Flutter binaries as inspectable artifacts: never embed database credentials, API secrets, signing keys, or production service credentials. Use separate staging/production endpoints and credentials. Native clients do not rely on browser CSRF cookies; browser writes retain CSRF protection. All authorization checks remain server-side for both transports.
- Native clients must serialize refresh calls per session. Concurrent reuse of the same consumed refresh token triggers session-family revocation. Store the returned token pair atomically in OS secure storage; if a refresh response is lost, do not retry the consumed token and require reauthentication if `/me` cannot confirm a current access token.
- Never log request bodies or `Authorization` headers on native authentication routes. Validation failures and database errors return sanitized messages; safe diagnostics record only exception types, never SQL parameters, credentials or token hashes.

## Web and API controls

- HTTPS only for deployed native login, refresh, logout and bearer API requests; enable secure cookie flags and HSTS after HTTPS behavior is validated. `SPARE_PARTS_NATIVE_HTTPS_REQUIRED=true` enforces the native transport requirement independently of cookie settings. Behind TLS termination, configure the ASGI server to trust scheme forwarding only from known proxies; do not trust client-supplied forwarding headers. Disable native HTTPS enforcement only for isolated local development.
- Use CSRF protection for cookie-authenticated mutations, strict origin checks as defense in depth, and a restrictive Content Security Policy.
- Escape rendered values; parameterize database access through SQLAlchemy; validate and bound request data; avoid unsafe dynamic SQL and file upload features unless separately designed.
- Authorization is checked server-side for every protected page and API request. Owner-only routes are explicit.
- Owner/attendant catalogue authorization is enforced in route dependencies and product ownership checks. Attendants can create submissions and edit only their own pending entries; only owners can approve/reject or set prices. Product images are decoded/re-encoded, assigned opaque random storage keys, kept outside the static tree, and served only through the authenticated product-visibility check.
- Baseline CSP, MIME-sniffing, referrer and frame headers are applied by the app. Scripts are same-origin with no inline scripts permitted. Inline styles remain allowed because the fictional demo chart computes bar heights in style attributes. HTTPS redirect, HSTS, request-size limits, and edge rate limits remain deployment responsibilities. Avoid permissive CORS; same-origin is preferred.

## Data and infrastructure

- Keep PostgreSQL on a private network, require TLS for application connections where supported, and use a least-privilege application role distinct from migration/admin credentials.
- Store secrets in a cloud secret manager or protected runtime configuration; never commit secrets or log credentials, cookies, password reset tokens, or full payment details.
- Encrypt provider-managed storage/backups and define retention and restoration access. Restrict production console, deployment, database, and secret access to named maintainers.
- Patch dependencies and base images; pin and review dependencies; scan build artifacts and dependency vulnerabilities using an agreed process.
- Separate development, staging and production data/configuration. Never copy real customer/business data into development without an approved protected process.
- The current local product-image adapter is not production cloud storage. Production needs a private object-storage adapter, access policy, durable backup/lifecycle management, upload request limits at the edge, and monitoring for storage errors/orphaned files. Keep image buckets/private objects inaccessible to public listing and direct anonymous reads.

## Audit and privacy

Record authentication events and material product, pricing, inventory, purchase, sale, and account actions with actor, timestamp, target and safe context. Do not allow ordinary application flows to alter/delete audit history. Exclude secrets and minimize personal data. Define retention, access and export policy before launch.

## Operational response

- Monitor application errors, availability, failed logins, database health, disk/storage and backup completion without logging sensitive payloads.
- Define incident contacts, credential rotation, backup restore steps and recovery objectives before production.
- Test backup restoration in a non-production environment. Confirm migration backup/rollback steps before releases.

## Decisions and risks

Open: MFA requirement, password reset/recovery procedure, confirmation of the provisional session, throttle and audit-retention values, cloud/provider region and controls, backup encryption/retention, monitoring response owner, data privacy obligations, and recovery targets. Per-peer throttling cannot stop distributed attacks and can affect users sharing a public peer behind a proxy or NAT. In production, configure the ASGI server to trust forwarding metadata only from known proxies that strip and replace client-supplied values; otherwise keep proxy rewriting disabled and apply rate limits at the edge. Add edge-level distributed and request-volume controls. A cloud host's default security configuration is not a substitute for verifying these controls.
