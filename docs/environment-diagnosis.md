# Environment and foundation diagnosis

## Scope and method

This is a read-only environment and static-code review. No packages were installed, no network/package settings were changed, and neither `.venv` nor `.venv-dev` was deleted, reset, or rebuilt. The foundation files and existing documentation were inspected. The Python executable was used only to report interpreter details; package imports/tests were not run because the dependencies are absent.

## Confirmed environment

| Question | Finding |
|---|---|
| Terminal operating system | Windows 11, build reported by Python as `Windows-11-10.0.26300-SP0`; terminal is Windows PowerShell 5.1.26100.9711. |
| Python executable | `C:\Users\DELL\Developer\spare-parts-system\.venv-dev\Scripts\python.exe`, CPython 3.13.16. Its base interpreter is `C:\Users\DELL\AppData\Local\Python\pythoncore-3.13-64`. |
| Active project environment | `.venv-dev` is a Windows virtual environment. Its `pyvenv.cfg` points to the Windows CPython 3.13.16 base. It has no `pip` module or installed application dependencies. |
| Existing `.venv` | A separate Linux CPython 3.12 environment: `pyvenv.cfg` records `/usr/bin/python`, Python 3.12.3, and a WSL-style project path. It does not belong to the current Windows terminal. Its Python launchers are Linux-style and unusable from Windows. |
| Git repository | Initialized on branch `master`. Git is available. No changes were staged at the time of inspection. |

## Package source, network, and caches

The previous `uv lock` attempt reached `https://pypi.org/simple/pwdlib/` and failed while opening a TCP connection with Windows socket error 10013 (“access forbidden”). This is a network access denial before package metadata resolution; it does not indicate an incompatible dependency version.

No `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `PIP_INDEX_URL`, `PIP_EXTRA_INDEX_URL`, `UV_INDEX_URL`, or related config environment variables were present. WinHTTP reports direct access, and the current-user WinINet proxy is disabled. No pip or uv index/proxy config file was found in the standard user/config locations inspected. The evidence points to the execution environment or host firewall blocking outbound connections, with no configured proxy or alternate package index. No network setting should be changed to work around this restriction.

Local cache findings:

- pip's cache contains about 27 MB of HTTP cache, but its wheel cache has zero locally built wheels. The HTTP cache is not a dependable complete source for the pinned dependency set.
- uv's user cache has cached archives for some packages, including Jinja2, FastAPI, and Uvicorn, but those versions do not match all project pins. The cache does not contain several required direct packages (including Alembic, SQLAlchemy, Psycopg, pwdlib, pydantic-settings, HTTPX, pytest, and python-dotenv).
- An offline uv dry-run could not inspect its standard cache because access to `...uv\cache\sdists-v10\.git` is denied. It did not install anything.
- `.uv-cache` was created by the earlier uv attempt. Its own generated `.gitignore` ignores its contents, so Git does not report it, but the project `.gitignore` has no explicit `.uv-cache/` entry.

**Diagnosis:** the current caches cannot be relied on to install the full declared set. The safe route is to use official PyPI after outbound access has been approved/restored, or a wheelhouse supplied by the organization from an explicitly trusted source. Do not change indexes to an unreviewed mirror or disable TLS verification.

## Git hygiene

| Path | Tracked / ignored status | Finding |
|---|---|---|
| `.venv/` | Tracked | `git ls-files .venv` reports 1,014 tracked paths. The root ignore rule cannot ignore already tracked files. Git reports modifications to `.venv/bin/python`, `.venv/bin/python3`, `.venv/bin/python3.12`, and deletion of `.venv/lib64`. These existed before this diagnosis and were not changed here. |
| `.venv-dev/` | Ignored | The root `.gitignore` rule `.venv-*/` covers it. It is the correct environment for this Windows checkout. |
| `.uv-cache/` | Contents ignored by its generated local `.gitignore` | There is no explicit root ignore entry. Add `.uv-cache/` to the project `.gitignore` so behavior does not depend on the cache's own nested file. |
| `.env` | Ignored | Root `.gitignore` includes `.env` and `.env.*`, with an exception for `.env.example`. No secret file was added by this diagnosis. |

The working tree also contains the foundation changes from Task 003: modified `README.md` and untracked `.env.example`, `.gitignore`, `alembic.ini`, `app/`, `migrations/`, `pyproject.toml`, `requirements.txt`, and `tests/`. None were reset or staged. The `.venv` modifications are separate environment artifacts, not application source.

**Safe tracked-environment correction:** first checkpoint/review the application work. Then remove only the virtual environment entries from Git's index and commit that cleanup separately. `git rm --cached` leaves the working directory environment in place; it does not remove the local environment. Keep `.venv/` in `.gitignore`. Because `.venv` is currently modified, inspect the staged result carefully before committing; do not use `git clean`, reset, or delete the directory. Prefer a future clean checkout/environment recreation after the project has recorded its actual runtime/dependency setup.

Suggested commands, to run only as a deliberate Git cleanup after reviewing current work:

```powershell
git status --short
git rm --cached -r --force -- .venv
git diff --cached --stat -- .venv
git status --short
```

The `--cached` option retains the local `.venv` files. The deletion is from repository history going forward, not from disk; commit it separately after confirming that is intended.

## Dependency declaration review

- Every direct package is pinned with `==` in `requirements.txt` and in `pyproject.toml`; the overlapping versions match. `httpx` and `pytest` are declared as development dependencies in `pyproject.toml` and are also present in `requirements.txt`.
- There is no direct version conflict in the declarations. `requires-python = ">=3.13,<3.14"` matches the confirmed interpreter.
- PyPI release metadata for the selected direct versions does not declare a Python upper bound below 3.13. For example, FastAPI 0.115.12 declares Python >=3.10; SQLAlchemy 2.0.40 is tagged for CPython 3.13 Windows x64; Alembic 1.15.2 declares Python >=3.9; Psycopg 3.2.6 declares Python >=3.10; and Uvicorn 0.34.0 declares Python >=3.9. Jinja2 3.1.6 declares Python >=3.7, while HTTPX 0.28.1 declares Python >=3.8. These metadata constraints allow 3.13, but metadata compatibility is not a substitute for running the application and tests. [FastAPI](https://pypi.org/project/fastapi/0.115.12/), [SQLAlchemy](https://pypi.org/project/SQLAlchemy/2.0.40/), [Alembic](https://pypi.org/project/alembic/1.15.2/), [Psycopg](https://pypi.org/project/psycopg/3.2.6/), [Uvicorn](https://pypi.org/project/uvicorn/0.34.0/), [Jinja2](https://pypi.org/project/Jinja2/3.1.6/), [HTTPX](https://pypi.org/project/httpx/0.28.1/).
- `pwdlib` 0.2.1 and python-dotenv 1.0.1 declare Python >=3.8; pydantic-settings 2.8.1 ships a universal wheel; pytest 8.3.5 supports Python 3.10 and newer. The `pwdlib` 0.2.1 classifiers list only through Python 3.12, so Python 3.13 operation of that exact pin is not explicitly advertised by its classifier even though `Requires-Python` does not exclude it. Confirm by installing from the trusted source and running the hash tests. [pwdlib](https://pypi.org/project/pwdlib/0.2.1/), [python-dotenv](https://pypi.org/project/python-dotenv/1.0.1/), [pydantic-settings](https://pypi.org/project/pydantic-settings/2.8.1/), [pytest](https://pypi.org/project/pytest/8.3.5/).
- The exact pins cover direct requirements, not the full transitive dependency graph. No `uv.lock` exists because resolution could not complete. Once the package source is available, generate and review a lock file so transitive versions are repeatable.
- The two declaration files duplicate direct package versions. They are currently consistent, but a lock file and one documented install path should be the source of repeatable environment setup.

## Static code review

### Findings to address

1. **README install command fails for the created environment.** `.venv-dev` was created with uv and has no `pip` module. The documented command `.venv-dev\Scripts\python.exe -m pip install -r requirements.txt` therefore fails (`No module named pip`). Use `uv pip install --python .venv-dev\Scripts\python.exe ...`, or install pip into the venv deliberately after confirming the package source. Do not rebuild/overwrite either current environment.
2. **Alembic autogeneration will not discover future models automatically.** `migrations/env.py` sets `target_metadata = Base.metadata` but imports no model modules. There are currently no application models, so the empty foundation revision is expected; when model modules are added, import them before assigning metadata or `--autogenerate` can produce an empty migration.
3. **Database connection timeout is not bounded.** `create_database_engine` enables `pool_pre_ping`, but sets no connection timeout. A reachable-but-unresponsive or unroutable database may keep `/health/ready` occupied for the driver's default timeout. Configure a deliberate PostgreSQL connection timeout and test the resulting response before production.
4. **The database-failure test uses a DNS hostname as its failure mechanism.** `test_readiness_returns_sanitized_unavailable_response` connects to host `invalid`; DNS/network behavior can make this test slow or environment-dependent. Replace the failure with a deterministic test double/SQLAlchemy exception once dependencies can be run.
5. **The password helper is not a complete authentication system.** Static inspection confirms only Argon2-capable hash/verify primitives. There is no user model, login, session/revocation, owner bootstrap, authorization dependency, CSRF mechanism, or audit integration. This is a scope boundary to resolve in the authentication milestone, not a reason to invent owner/session policy here.

### Areas that look sound from static inspection

- Settings are environment-backed with `SPARE_PARTS_` names; `.env` is locally read and ignored by Git. The default database URL contains no credentials.
- The PostgreSQL SQLAlchemy engine is lazy with respect to network connection, so app import/liveness need not connect to the database. Request sessions use a context manager and the FastAPI lifespan disposes the engine.
- `/health/live` is independent from dependencies. `/health/ready` runs `SELECT 1`, returns 503 on SQLAlchemy database failures, and does not include connection details in its response.
- The password module uses `pwdlib.PasswordHash.recommended()` with the Argon2 extra declared and rejects empty input. Hash tests cover non-plaintext storage and matching/mismatching passwords, though they remain unexecuted.
- The frontend includes viewport metadata, mobile navigation toggling, CSS breakpoints at 940px and 560px, and a skip link. Static review found no desktop/mobile layout defect.
- The test set covers page rendering, liveness without a database, successful and failed readiness, and password hashing. It does not cover real PostgreSQL, migrations, environment parsing, static asset requests, or responsive behavior in a browser.

## Safe dependency installation recommendation

Do not install from the current cache: it cannot meet the full exact-pin set. Once an administrator confirms official PyPI access (or provides an approved complete wheelhouse), use uv's own installer because this venv has no pip. Point uv at a new writable cache path instead of the currently permission-blocked cache, resolve the project, and synchronize the already-existing Windows venv:

```powershell
$env:UV_CACHE_DIR = Join-Path $env:LOCALAPPDATA 'uv\spare-parts-system-cache'
uv lock
. .\.venv-dev\Scripts\Activate.ps1
uv sync --active --all-groups --no-install-project
```

Review the resulting `uv.lock` and dependency diff. Do not add a custom index or disable TLS verification. If organization policy instead supplies wheel files, verify their origin and hashes first, then install only from that approved wheelhouse.

## Exact next commands

After the package source is confirmed and dependencies synchronize successfully:

```powershell
# From the repository root, after the command block above
python -m compileall -q app migrations tests
python -m pytest
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

In a second terminal, verify liveness and readiness:

```powershell
Invoke-RestMethod http://127.0.0.1:8000/health/live
Invoke-RestMethod http://127.0.0.1:8000/health/ready
```

The second request requires PostgreSQL configured through `SPARE_PARTS_DATABASE_URL` in the ignored `.env` or process environment. Then apply the empty foundation migration against that local database:

```powershell
python -m alembic upgrade head
```

For the Git-index cleanup of `.venv`, use the separate review commands above; do not combine that cleanup with dependency installation or app changes.
