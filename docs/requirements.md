# Requirements specification

## Status and interpretation

This document captures the owner's supplied task as the authoritative initial scope. It distinguishes **Confirmed** (explicitly specified), **Assumption** (a planning premise that must be validated), and **Open decision** (behavior must not be finalized until the owner decides).

## Confirmed requirements

- One initial business and one owner account.
- The attendant operates the shop from a Windows application. The owner remotely manages the business from an iPhone. Both access the same centralized records; Android is the developer's first test device.
- Installable application using one shared Flutter/Dart frontend codebase for Windows desktop, Android, and iOS. The client explicitly prefers an application over a browser app; do not wrap the web app in a WebView.
- Windows is the attendant's daily shop client; Android is the developer's first device test target; iOS is the owner's remote client.
- Retain Python, FastAPI, PostgreSQL, SQLAlchemy, Alembic, HTTPS, and cloud deployment for the backend. Flutter clients use authenticated APIs only; they never connect directly to PostgreSQL.
- All platforms share the same cloud-hosted business records. Internet access is required for normal operations; offline synchronization is excluded.
- Version 1 capabilities: dashboard; product and inventory management; sales and checkout; supplier management; stock receiving and purchases; printable receipts; sales history; basic reporting; authentication and audit logging.
- Exclusions: full accounting, M-PESA unless separately approved, unnecessary paid APIs, unapproved business rules, unrestricted stock adjustments, deployment of untested code.
- TASK 008 confirms two roles for the product catalogue: owner and shop attendant. Owners approve/reject submissions, set prices and manage attendant accounts. Attendants submit products and edit their own pending submissions.
- TASK 008 confirms catalogue fields: generated internal reference, required name, optional description/category/manufacturer part number/image, and pending/approved/rejected state. Manufacturer part numbers and product names are not unique identifiers.
- Selling price is required before approval and is stored with a decimal type. Currency and tax remain unconfigured and unresolved.
- Product photographs accept JPEG, PNG and WebP only, are decoded and re-encoded, and are retrieved only through authenticated access checks. Local filesystem storage is a development adapter, not the final cloud storage choice.
- Role-aware navigation is shared in Flutter, while server-side API authorization remains authoritative. Android staging tests precede an owner iOS beta distributed through TestFlight.
- iOS build/signing requires macOS and Xcode. The Windows 11 development host needs a hosted macOS build provider or an available Mac for iOS artifacts.
- The Windows receipt printer model and interface are unknown. Printing strategy must be confirmed against the actual device before promising direct thermal control.

## Users and access

- Confirmed users: initial owner and named shop attendants for the product submission workflow.
- Owner uses the iOS app for remote business management; attendant uses the Windows app for daily shop work. Android is initially for developer testing.
- Owner is authenticated for business data and administration; no anonymous access to operational screens or APIs.
- Open decision: any roles beyond owner and attendant, and whether one owner login can be used concurrently on multiple devices.

## Functional requirements

1. **Dashboard:** summarize useful business and stock indicators with a selected reporting period. Exact metrics, defaults and low-stock definitions are open decisions.
2. **Products:** create pending submissions, view/search products, edit own pending submissions, approve/reject as owner, and retain rejected history. The current catalogue uses generated internal references, optional category/manufacturer part number, and does not enforce manufacturer part-number or name uniqueness. Barcode, unit, compatibility, currency and tax decisions remain open. Stock, sales and checkout are not part of this catalogue milestone.
3. **Inventory:** show stock-on-hand and its movement history; expose current quantities without allowing arbitrary edits. Thresholds and stock valuation are open decisions.
4. **Sales and checkout:** capture a sale, its line items and payment details, update inventory consistently, and show a printable receipt. Discounts, tax, tender types, change, returns/voids, and stock shortage policy are open decisions.
5. **Suppliers:** manage supplier records and associate purchases/receipts with suppliers. Required contact fields and duplicate rules are open decisions.
6. **Purchases and receiving:** record supplier purchase documents and received quantities, and increase stock only when receipt is posted. Partial receipts, costs, purchase statuses and editing/cancellation rules need confirmation.
7. **Receipts:** render a print-friendly receipt containing a unique reference and sale details. Legal/tax content, paper width, branding, and whether to include customer details are open decisions.
8. **Sales history:** search and filter recorded sales; exact filters and permitted correction process require confirmation.
9. **Basic reports:** date-filtered sales and inventory views with export needs to be decided. Reports are operational, not accounting statements.
10. **Authentication and audit:** protect access and record attributable, timestamped audit events for material actions. Retention and audit visibility/export are open decisions.

## Platform acceptance requirements

- **Windows attendant app:** desktop-oriented product search and daily shop workflows, keyboard and mouse support, local image selection, receipt preview/printing, and clear connection/server errors. Do not guarantee printer-specific behavior before testing the shop's actual printer.
- **Android developer build:** installable staging build tested before the iOS owner beta, including separate owner and attendant accounts, product registration/image uploads, navigation, refresh, session expiry/logout, and connection failures.
- **iOS owner app:** build-compatible target with owner-only screens, remote catalogue review/price approval, product photographs, and stock/sales monitoring when those backend workflows exist. Store credentials in OS secure storage and support revocation/logout. Distribute the owner beta through TestFlight.
- **Shared behavior:** a single Flutter codebase, role-specific navigation, server-enforced permissions, common business models/API layer, and platform adapters for secure storage, image selection and printing. The interface is not a WebView.
- **Connectivity:** internet is required for normal use. Do not add offline synchronization or queue business mutations as successful while disconnected.

## Quality requirements

- Central authoritative database, accessible from both devices over the internet.
- HTTPS for all public traffic.
- Adaptive Flutter layouts for desktop and phone, with touch, keyboard and mouse support appropriate to each platform.
- Clear connection, authentication-expiry, server-error, and retry behavior. Since offline synchronization is excluded, the client must not represent queued business writes as completed.
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
- No printer model is assumed. Receipt print strategy is open until the shop printer and driver/interface are identified.
