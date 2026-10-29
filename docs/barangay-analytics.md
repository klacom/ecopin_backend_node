# PDT-16: barangay operational analytics

Implemented locally on 29 October 2026. Web route: `/analytics/barangay`, linked from the existing officer and administrator workspace navigation. API: authenticated `GET /api/analytics/barangay?startMonth=YYYY-MM&endMonth=YYYY-MM`. No production migration or deployment was performed.

## Decisions supported

| Evidence | Decision it can inform | Interpretation limit |
| --- | --- | --- |
| Monthly report counts for all 30 barangays | Review recurring service demand before changing collection schedules or prevention work | Reporting activity is not measured waste tonnage, population-adjusted incidence or a causal forecast |
| Verification processed percentage and pending count | Review validation queue coverage and reviewer capacity | Approved/rejected can include automated decisions; this is not human review speed |
| Current open backlog and age bands | Review cleanup staffing, access blockers and work waiting longest | Snapshot includes older and assigned work; not a historical end-of-month backlog |
| Median, average and 90th-percentile resolution hours with sample counts | Investigate response bottlenecks and the slow tail of resolved work | Small samples and issue mix limit comparisons; unresolved work is not included in these durations |
| Unassigned locations and missing/invalid timestamps | Prioritize boundary reconciliation and operational record quality | Missing measurements must not become zeros or silently disappear from totals |

PDT-17 supersedes the initial three highest-count prompts with versioned, explainable rule cards. Rules use complete-month growth, current backlog, verification denominators and resolution samples, with resource prerequisites and no automatic allocation. See [municipal decision proposals](../../ecopin-web/docs/municipal-decisions.md) for the current policy and validation. Unassigned locations remain separate.

## Metric contract

- **Calendar:** Asia/Manila, six inclusive months by default, configurable from January 2000 through the current month, at most 24 months per request. Month starts are inclusive and the following month start is exclusive. The current month is explicitly incomplete. The database supplies one generated-at snapshot.
- **Sources:** internal `reports`, official `pasig_barangay_roster`, and the authenticated actor's profile role. The browser receives aggregates only; no report IDs, citizen identities, notes, photos or precise coordinates are projected. No external barangay submissions or new feeds are needed.
- **Area:** a report enters a named barangay only when PDT-08 records `barangay_resolution_status = 'resolved'` and its name matches the protected roster. All 30 rows always appear, including San Miguel. Ortigas Center remains a district. Border, outside-baseline, pending and unknown assignments enter Unassigned location, which remains part of All locations totals. A zero in a named barangay does not prove no incidents occurred there.
- **Submitted volume:** number of reports created in the selected months, including pending and rejected submissions. Monthly series includes zero months. Creation timestamps that are missing, non-finite or in the future are excluded with a quality count.
- **Verification processed:** current `approved`/legacy `validated` plus `rejected` validation states, divided by all submissions created in the selected months. Pending includes every other/unknown validation state. Denominator and approved/rejected counts are exported. This describes current states of creation cohorts, not what officers processed during each historical month.
- **Current backlog:** all recorded reports at the generated-at time whose response status is not resolved/completed/closed/waiting_for_feedback/rejected/withdrawn/cancelled and whose validation is not rejected. Assignment does not exclude a report. Age is elapsed time from creation: under 24h, 24–<72h, 72–<168h, 168–<720h, and 720h+. Display labels are Under 1 day, 1–2 days, 3–6 days, 7–29 days and 30+ days.
- **Resolution duration:** creation to `lgu_resolved_at` for currently resolved/completed/closed/waiting-for-feedback records whose resolution event falls in the selected months. Older submissions resolved during those months are included. Missing, negative or future durations are excluded; `updated_at` and `citizen_closed_at` are never substitutes. Median/P90 use PostgreSQL continuous percentiles, including interpolation. No samples returns NULL and displays an em dash.
- **Resolution quality:** missing/invalid resolution timestamp counts cover currently resolved records across all stored history, independently of the month selection. Resolution metrics are recorded SWMO events, not proof of GPS presence or cleanup quality.

## Interface and access

The existing dashboard shell and staff session are reused at the requested route. Only officer/admin roles mount the analytics component. The existing protected web proxy forwards the single GET path using its server-held session; it is not a public endpoint. Backend middleware checks staff roles and the service-only, SECURITY INVOKER database function independently verifies the actor's current profile role. Anonymous/authenticated direct RPC execution is revoked. No public report view or existing report RLS policy is changed.

Month drafts require Apply months. Trend area changes the charts, while the comparison table retains all 30 barangays and unassigned locations, with search and sorting. Native written chart values remain available without color/canvas. The table scrolls within its own keyboard-accessible region on narrow screens. Coverage details can expand; gap counts remain visible when collapsed.

Initial errors show a retry and no invented figures. Refresh errors retain the last successful period/snapshot with a stale notice and disable export. 401/403 clears loaded figures. Response consistency checks reject incomplete partitions and coverage. CSV includes All locations, all 30 barangays, the unassigned bucket, monthly series, sample counts, denominators, applied dates and scope notes. It exports the last successfully applied full range rather than a search subset or unsaved draft; risky spreadsheet cell prefixes are escaped. Download feedback says the browser download started.

## Deployment and rollback

1. Apply PDT-08 `20261029050000_reconcile_pasig_barangay_boundaries.sql` and complete its staged PostGIS acceptance first. Its audit found a highly simplified derivative dataset; this dashboard does not certify precise legal boundaries.
2. Stage and apply `20261029060000_barangay_operational_analytics.sql`. It only creates an aggregate RPC/grants and does not backfill or mutate reports. The function requires the 30-row roster and reconciled-location fields.
3. Complete the explicitly reviewed PDT-08 report-address reconciliation/backfill. Until then, pending legacy labels stay unassigned. Do not present blank official-area counts as a completed baseline.
4. Deploy backend before web; verify officer/admin GET succeeds with production data, anonymous/citizen/crew access fails, totals sum across 31 area rows, and missing timestamps remain excluded. This live smoke test was not performed because migrations are not deployed.
5. Compare execution plans/latency on the real dataset. The aggregate scans eligible report history to produce current backlog and quality figures; the bounded month range controls returned series, not the amount of historical data read. Introduce rollups only if measured volume requires them.

Rollback: withdraw the page/navigation and backend route, then optionally drop the new RPC. No report data restoration is required for this migration. The dashboard is strictly read-only.

## Initial PDT-16 verification (before the decision-card extension)

- Nine PGlite tests execute the real aggregate migration and SQL (no spatial stubs needed). They cover canonical coverage, Manila boundaries, review denominators, old-submission resolution events, invalid/missing timestamps, empty periods, backlog cutoffs and role restrictions.
- Eleven backend API tests cover sanitized month ranges, Manila defaults, trusted actor identity, non-staff denial and unavailable-migration feedback.
- Seven web unit tests cover range defaults, decision prompts, sorting, CSV escaping, missing durations, response consistency and the protected proxy allowlist.
- Browser checks use intercepted synthetic staff sessions/data at 1440px light/officer, 768px dark/admin and 320px dark/officer. They verify all 31 area rows, San Miguel, absence of Ortigas as a barangay, area/search filters, CSV, initial error/retry, stale refresh/recovery, no page overflow and no page runtime errors. Screenshots of summary, charts and comparison were inspected. These are test fixtures, not live production metrics; no demo data fallback is shipped.
- Production Next.js build passes. Changed analytics scopes lint without errors/warnings; Sidebar retains its pre-existing avatar `<img>` warning.
- Broad backend verification passes 337 Jest tests and 68 Node database checks; one additional analytics role test was subsequently added and passes in the nine-test focused SQL run. The default test command now runs Jest `.test.js` and Node `.test.mjs` separately instead of handing both formats to Jest. No database checks were skipped.
- Browser evidence: `ecopin-web/.ui-review/pdt16/`. Backend log: `.tmp/pdt16-tests.log`. Web logs: `.ui-review/pdt16/unit-tests.log` and `build.log`.

Useful checks from their respective repositories:

```powershell
# Backend
npm test
npm run test:barangay-analytics:db
# Web
npm test
npm run build
# Local browser check: use installed Playwright/Chromium paths when needed.
node tests/barangay-analytics.browser.cjs
```
