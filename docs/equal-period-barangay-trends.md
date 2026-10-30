# PDT-18 — Equal-period barangay trends

Locally implemented; hosted migration/deployment remains pending.

## Counting contract

The existing staff-only `get_barangay_operational_analytics` RPC now adds `trend_periods` and a `trend` on every official barangay, unassigned bucket and city total. The PDT-31 executive wrapper receives these fields in its existing single database snapshot; no new API endpoint is needed.

Select the latest complete Manila calendar month within the applied range. At the following month's midnight, compare the preceding 30 days against the immediately preceding 30 days. Windows are half-open, non-overlapping and exactly 30 days each, even across leap years. They may extend before the applied month range. A selection containing only the current incomplete month has unavailable trends, never a fabricated zero. Monthly totals and current all-time backlog retain their distinct scopes.

Example: September 2026 uses September 1–October 1 versus August 2–September 1, end dates excluded. Calendar August's 31-day count is never the baseline.

Counts include all submissions, with current reconciled boundary assignments and an explicit unassigned bucket. They measure reporting participation, not tonnage or incidence. No report records or identities are added to payloads.

## Presentation and recommendations

- Positive baseline: `(current - previous) / previous * 100`, rounded only for display; both counts remain visible.
- Zero baseline plus positive count: **New Activity**, null percentage.
- Both counts zero: **No activity**, null percentage.
- Decrease to zero: **-100%**.
- Previous count below 8 or current below 10: **Small sample** note.
- Missing/mismatched windows, invalid counts or totals: **Unavailable**, never fall back to unequal calendar-month growth.

The dashboard focus panel, all-area comparison, CSV and A4 executive appendix share the same presentation rules. Rule policy PDT-17.2 consumes equal-window counts and location coverage. Existing minimum counts, backlog, freshness, historical-range and two-complete-month selection safeguards remain in force. A percentage is descriptive, not proof of a sustained trend; zero/small baselines do not trigger collection growth allocations.

## Migration and verification

Apply `migrations/20261030020000_equal_period_barangay_trends.sql` after PDT-16's aggregate migration; it replaces the function without renaming or dropping its signature. The replacement remains STABLE, SECURITY INVOKER with empty search_path, officer/admin actor authorization and service_role-only execution. No table policies or grants are broadened. The optional PDT-31 wrapper automatically uses the new aggregate once installed.

Regression coverage executes the real SQL in isolated PGlite: leap February, exact Manila window edges, session timezone independence, city/area reconciliation, zero baseline, empty areas, partial months, staff authorization and RPC grants. Web tests cover normalization and missing data, compare independently counted trend observations against intentionally unrelated monthly totals, and retain rule threshold tests. Chromium checks use synthetic fixtures across 1440/768/320px, CSV, stale/retry and print gates. Hosted data, query plans at production scale, deployment and physical printers remain unverified.


Local results (2026-10-30): 12 SQL integration cases, 35 focused analytics cases, 146 default web unit cases plus six deadline cases, 46 backend Jest suites / 405 cases, scoped lint and production build passed. Chromium dashboard and executive-summary checks passed for officer 1440px light, admin 768px dark and officer 320px dark. Synthetic A4 samples contain 11 / 10 pages; all text remains within page bounds, and the new trend table renders with repeating headers. The default backend Jest command also discovers Node `.mjs` tests incorrectly; Jest was run with `--testMatch '**/*.test.js'`, with the relevant `.mjs` database suite executed separately using Node.
