# Requirements specification

## Status and interpretation

This document captures the owner's supplied task as the authoritative initial scope. It distinguishes **Confirmed** (explicitly specified), **Assumption** (a planning premise that must be validated), and **Open decision** (behavior must not be finalized until the owner decides).

## Confirmed requirements

- One initial business and one owner account.
- Owner accesses the system on a Windows computer at the shop and a smartphone from anywhere with internet access. Both use the same centralized records.
- Responsive web application; no separate native Android or Windows client.
- Approved direction: Python, FastAPI, PostgreSQL, SQLAlchemy, Alembic, HTML, CSS, JavaScript, Chart.js, HTTPS and cloud deployment.
- Version 1 capabilities: dashboard; product and inventory management; sales and checkout; supplier management; stock receiving and purchases; printable receipts; sales history; basic reporting; authentication and audit logging.
- Exclusions: full accounting, M-PESA unless separately approved, unnecessary paid APIs, unapproved business rules, unrestricted stock adjustments, deployment of untested code.

## Users and access

- Confirmed initial user: shop owner.
- Assumption for design: owner is authenticated for all business data and administration; no anonymous access to operational screens or APIs.
- Open decision: whether employees or additional roles are expected soon, and whether one owner login can be used concurrently on multiple devices.

## Functional requirements

1. **Dashboard:** summarize useful business and stock indicators with a selected reporting period. Exact metrics, defaults and low-stock definitions are open decisions.
2. **Products:** create, view, edit, search and deactivate products. Product identifiers, barcode support, categories, units, pricing and duplicate rules require owner confirmation.
3. **Inventory:** show stock-on-hand and its movement history; expose current quantities without allowing arbitrary edits. Thresholds and stock valuation are open decisions.
4. **Sales and checkout:** capture a sale, its line items and payment details, update inventory consistently, and show a printable receipt. Discounts, tax, tender types, change, returns/voids, and stock shortage policy are open decisions.
5. **Suppliers:** manage supplier records and associate purchases/receipts with suppliers. Required contact fields and duplicate rules are open decisions.
6. **Purchases and receiving:** record supplier purchase documents and received quantities, and increase stock only when receipt is posted. Partial receipts, costs, purchase statuses and editing/cancellation rules need confirmation.
7. **Receipts:** render a print-friendly receipt containing a unique reference and sale details. Legal/tax content, paper width, branding, and whether to include customer details are open decisions.
8. **Sales history:** search and filter recorded sales; exact filters and permitted correction process require confirmation.
9. **Basic reports:** date-filtered sales and inventory views with export needs to be decided. Reports are operational, not accounting statements.
10. **Authentication and audit:** protect access and record attributable, timestamped audit events for material actions. Retention and audit visibility/export are open decisions.

## Quality requirements

- Central authoritative database, accessible from both devices over the internet.
- HTTPS for all public traffic.
- Responsive layouts for desktop and phone, usable without a native client.
- Transactional consistency for checkout and receiving so partial writes cannot create mismatched sales and stock.
- Use decimal monetary values and explicit currency configuration; currency is an open decision (Kenyan context suggests KES, but this was not specified as a rule).
- Backups, recovery objectives, monitoring, availability targets and data retention must be decided before production launch.

## Open business decisions (must be settled before implementing dependent workflows)

1. Currency, tax/VAT treatment, receipt fiscal/legal requirements, and any tax-inclusive/exclusive pricing convention.
2. Product model: SKU/barcode uniqueness, category, unit of measure, part compatibility/vehicle fitment, variants, and whether negative stock is permitted.
3. Pricing: default selling price, cost tracking, margin visibility, price changes, line/order discounts, and rounding behavior.
4. Sale policy: accepted payment methods, split payments, amount due/change, whether payment is required to finalize, sale numbering, cancellation/void and return/refund workflow.
5. Purchase policy: purchase order vs direct receipt, partial receipt, cost capture, supplier invoice references, and handling damaged/returned stock.
6. Inventory controls: who can adjust, allowed reasons, approval or confirmation process, physical count workflow, and whether corrections are represented as ledger movements.
7. Alerts and reports: low-stock threshold, dashboard metrics, report periods/timezone, exports, and historical retention.
8. Receipt format and content; customer capture requirements.
9. Owner account bootstrap, password reset/contact channel, session lifetime, optional MFA, and future additional users.
10. Deployment region/provider, budget, domain, backups/recovery objectives, monitoring and operational support ownership.

## Planning assumptions (not commitments)

- A single-tenant schema is sufficient initially; records are not partitioned by shop/account.
- Posted sales and posted receipts are immutable financial/stock events. Corrections use explicit compensating events, subject to owner-approved policy.
- Inventory quantities are derived from an append-only stock movement ledger rather than a freely editable balance field. A cached balance may be maintained transactionally.
- Dates/times are stored in UTC and shown in a configured shop timezone, to be selected.
- Browser printing is sufficient for initial printable receipts; no direct printer integration is required.
