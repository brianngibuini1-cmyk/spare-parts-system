# Spare Parts Management System

A responsive, cloud-hosted web application for managing one spare parts shop. The owner will use it from a Windows computer at the shop or a smartphone with internet access; both clients use the same centralized PostgreSQL records.

## Planned technology

Python, FastAPI, PostgreSQL, SQLAlchemy, Alembic, server-rendered HTML/CSS/JavaScript and Chart.js. The application is designed for HTTPS and cloud deployment. It is not a native mobile or Windows application, a full accounting package, or an M-PESA integration.

## Version 1 scope

Dashboard, products, inventory, sales and checkout, suppliers, purchasing and receiving, printable receipts, sales history, basic reports, authentication and audit logging.

## Project status

Architecture and requirements planning only. No application has been implemented, dependencies installed, or infrastructure deployed. Business decisions still need owner input; see [Requirements](docs/requirements.md) and [Implementation plan](docs/implementation-plan.md).

## Architecture documents

- [Requirements specification](docs/requirements.md)
- [System architecture](docs/architecture.md)
- [Database design](docs/database-design.md)
- [API contracts](docs/api-contracts.md)
- [Security plan](docs/security-plan.md)
- [Implementation plan](docs/implementation-plan.md)

## Development

No runnable application or test suite exists yet. The project rules in [AGENTS.md](AGENTS.md) apply to future implementation work.
