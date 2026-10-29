# PDT-31: monthly barangay executive report

Status: locally complete, 29 October 2026. No hosted migration, deployment, commit or push performed.

## Workflow and scope

Metrics -> Barangay analytics -> Executive report month -> Print executive summary. The selector uses the applied analytics range, defaulting to its latest complete month; if only the current month is available it is explicitly month-to-date. Unapplied dates, refreshing, failed or mismatched dashboard snapshots disable the entry action. Existing CSV export remains available.

The role-guarded preview lives at `/dashboard/officer/metrics/barangay-print/:month`. Staff can apply a different month, reload, then choose Print / Save PDF. Use A4 portrait, Save as PDF or a physical printer, and disable browser-added headers/footers. Changing the month draft pauses printing until applied. Snapshot data older than 24 hours or more than five minutes ahead of the clock cannot print through the action. The print-time handler checks freshness again and commits the current interpretation clock before opening the dialog. Native printing preserves selectable Unicode text.

The opening page is a municipal executive overview for the Office of the City Mayor and City Council. It shows submissions, processed/pending verification, current workload and aged backlog, resolution sample counts/median/average/P90, coverage exclusions and the largest recorded official-barangay backlogs. Counts cover all EcoPin issue types, not measured waste tonnage or population-adjusted incidence.

Recommendations begin on a new page. Every matched proposal is included with area, action, observed evidence, trigger, rule IDs and prerequisites. Shared collection/crew checks print once and are explicitly referenced by the applicable proposals; no checks are discarded. Dashboard search, area/type filters and collapsed cards do not narrow the document. Existing PDT-17 rules remain unchanged, including partial-month, historical-range, small-baseline, location-coverage and age safeguards. Proposals never commit crews, vehicles or schedules.

The statistical appendix includes all 30 official barangays, the unassigned bucket and city totals in three tables: monthly submissions/current verification, current all-time backlog age bands, and selected-month resolution events. Missing or invalid timestamps remain explicit. Current backlog is not portrayed as historic month-end backlog. San Miguel is included and Ortigas Center is not counted as a barangay.

## Data contract

`GET /api/analytics/barangay/executive?month=YYYY-MM` requires an authenticated, nonsuspended Officer/Admin. The service-only read function `get_barangay_executive_analytics(actor,report_month)` delegates to existing validated aggregate SQL, returning selected-month metrics and the preceding+selected-month recommendation inputs within one STABLE statement snapshot. Both generated_at values and current backlog fields match. January 2000 clamps the comparison floor to the existing aggregate's lower bound. No raw reports, citizen identities, photos or free-text incident data are exposed.

The client validates version, month ranges, all official PSGC identities, complete monthly series, city/group reconciliations, shared snapshot time, selected-month count agreement and current-backlog agreement. Invalid or failed responses produce an unavailable state, clear previous print content and allow retry; no partial statistics are substituted.

Recurring hotspot context reuses PDT-19's separate historical-analysis API. It prints all current 90-day concentration groups, member-based barangay counts, center coordinates as inspection candidates, old/middle/latest non-overlapping 30-day counts, active UTC weeks, observed 7/30/90-day counts, parameters, exclusions and interpretation. Its own snapshot and exact rolling window are printed separately. This is not a reconstruction of the selected calendar month, a road identification or a future corridor forecast. Stale/incomplete/failed hotspot analysis is visibly unavailable, never zero; valid monthly statistics can still print. Forward prediction figures are not substituted for observed recurrence.

## Print implementation

The monthly and PDT-30 incident exports share A4PrintPortal, a single screen-hidden body portal and print boundary. Dynamic page rules supply the active report's margin header/footer and page counts, avoiding competing per-feature body-hiding rules after navigation. The dashboard shell, dialogs, controls and duplicate screen copy are excluded. Scoped document CSS provides white pages, readable text, repeated table headings and deliberate summary/recommendation/appendix breaks. No new runtime package, external PDF service, image capture or rasterized dashboard is used. Current Chromium is the verified browser; margin boxes/page counters depend on browser support.

## Verification

- Backend Jest: 45 suites / 401 tests passed, including seven new executive endpoint cases for month/role validation, authenticated actor binding and unavailable storage.
- PostgreSQL/PGlite analytics suite: 10 tests passed, including the actual wrapper and aggregate SQL. Selected-month scope, comparison range, identical source times/backlogs, January floor, invalid/future periods, nonstaff denial and direct authenticated-role denial are covered.
- Web: 158 unit + 6 deadline tests passed. New tests check scope/coverage mismatch, month rollover, stale/future data, absent versus zero hotspots and the private read-only proxy destination.
- Next production build and scoped ESLint passed.
- Executive Chromium fixtures: Officer 1440/light, Admin 768/dark, Officer 320/dark. The Metrics entry flow, unapplied dates, ignored dashboard search filter, all 31 areas in each table, every matched proposal, every engine concentration, print action, month draft, expired data, failed statistics/retry and optional hotspot failure passed with no document horizontal overflow or page runtime errors.
- Synthetic native PDFs: nine-page complete-month report and eight-page month-to-date/unavailable-hotspot report. Pypdf/pdfplumber verify A4 media boxes, every official barangay and unassigned row in all three tables, recommendation/recurrence evidence and notices, repeated table/document headings, page numbers, no dashboard controls, and all extracted words inside the page. Poppler pages were rendered and visually inspected. These files are synthetic acceptance evidence at ecopin-web/output/pdf/pdt31-*.pdf, not municipal data.
- PDT-30 browser regression passed after sharing the print boundary: Officer/Admin, 1440/light, 1440/dark and 320/dark, with full case history, proof readiness/failure, privacy sentinels, print and retry intact.

The PDF QA found and corrected an ambiguous month-selector accessible name and orphaned/repetitive recommendation presentation. The test harness explicitly resets print/screen emulation between successive PDFs so screen controls cannot masquerade as printed output. Existing recommendation policy and analytics formulas were not weakened.

## Release requirements

Apply PDT-08 reconciliation and PDT-16 aggregate prerequisites, then `20261029170000_barangay_executive_snapshot.sql`; deploy compatible backend and web. PDT-19 DB/ML setup is needed for live hotspot content. If unavailable, the report explicitly prints that limitation. The new migration only creates a service-only read function and does not change stored report data.

Hosted Supabase/PostgREST role and suspension checks, intended-schema consistency, live metric reconciliation, actual ML availability, current-browser print behavior and a real A4 printer remain release acceptance checks. PGlite/synthetic browser fixtures do not establish live readiness. PDF files are point-in-time snapshots and cannot be refreshed or revoked after distribution.
