# Security plan

## Threat-aware baseline

The system is internet-accessible and holds business and authentication data. The initial account is an owner, but that does not remove risks from stolen credentials, cross-site requests, injection, accidental data exposure, compromised dependencies, or lost backups.

## Identity and sessions

- Store only a modern, salted, deliberately slow password hash using a maintained password hashing library; never plaintext or reversible passwords.
- Bootstrap the first owner through a controlled one-time setup mechanism; do not ship a known default password. Disable setup after completion.
- Use secure, HTTP-only, SameSite cookies over HTTPS; rotate session identifiers after login and privilege changes; expire and revoke sessions. Exact idle/absolute lifetime is an owner decision.
- Protect login/reset endpoints with rate limiting and generic responses. Password reset channel, MFA, and recovery process require a decision.
- Do not place bearer credentials in URLs or browser local storage.

## Web and API controls

- HTTPS only; enable secure cookie flags and HSTS after HTTPS behavior is validated.
- Use CSRF protection for cookie-authenticated mutations, strict origin checks as defense in depth, and a restrictive Content Security Policy.
- Escape rendered values; parameterize database access through SQLAlchemy; validate and bound request data; avoid unsafe dynamic SQL and file upload features unless separately designed.
- Authorization is checked server-side for every protected page and API request. Owner-only routes are explicit.
- Apply security headers, request size limits, login throttling, and generic error responses. Avoid permissive CORS; same-origin is preferred.

## Data and infrastructure

- Keep PostgreSQL on a private network, require TLS for application connections where supported, and use a least-privilege application role distinct from migration/admin credentials.
- Store secrets in a cloud secret manager or protected runtime configuration; never commit secrets or log credentials, cookies, password reset tokens, or full payment details.
- Encrypt provider-managed storage/backups and define retention and restoration access. Restrict production console, deployment, database, and secret access to named maintainers.
- Patch dependencies and base images; pin and review dependencies; scan build artifacts and dependency vulnerabilities using an agreed process.
- Separate development, staging and production data/configuration. Never copy real customer/business data into development without an approved protected process.

## Audit and privacy

Record authentication events and material product, pricing, inventory, purchase, sale, and account actions with actor, timestamp, target and safe context. Do not allow ordinary application flows to alter/delete audit history. Exclude secrets and minimize personal data. Define retention, access and export policy before launch.

## Operational response

- Monitor application errors, availability, failed logins, database health, disk/storage and backup completion without logging sensitive payloads.
- Define incident contacts, credential rotation, backup restore steps and recovery objectives before production.
- Test backup restoration in a non-production environment. Confirm migration backup/rollback steps before releases.

## Decisions and risks

Open: MFA requirement, password policy and recovery channel, session duration, cloud/provider region and controls, backup encryption/retention, log/audit retention, monitoring response owner, data privacy obligations, and recovery targets. A cloud host's default security configuration is not a substitute for verifying these controls.
