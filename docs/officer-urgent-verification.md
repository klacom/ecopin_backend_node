# PDT-03: officer urgency queue and maturation bypass

Scope: officer/SWMO web dashboard and shared backend, building on PDT-01/PDT-02. A citizen's accepted Urgent submission creates a pending urgency request and durable officer/admin notifications atomically, including offline sync. A flag alone is not dispatch approval and does not alter trust.

Officers/admins can approve or decline urgency with a required reason. Current database role, self-review exclusion, expected current decision and unique operation UUID are checked on the server. Identical retries are idempotent; stale/conflicting decisions fail. Declining urgency does not label a citizen dishonest or reduce trust. Already assigned/closed/rejected reports cannot receive a new urgency decision.

Approved urgency bypasses only the maturation window: a validated, consent-cleared unresolved report can enter the existing dispatch flow immediately. SLA start/deadline, actual approval time, crew capacity/availability, access blocks, hazard and dispatch checks remain authoritative. Pending/unapproved urgency does not bypass normal maturation. A later decline restores normal age-based eligibility before assignment; it does not undo a dispatched task. Officer approval never promises that crew assignment or cleanup is already complete.

The web queue provides pending/approved/declined views, report inspection, decision reasons, failure retention and a focused link to prepare a dispatch plan using the existing planner/commit flow. A dashboard alert and compact queue keep requests visible. While a dashboard is open, bounded polling refreshes every five seconds; durable notifications are written immediately on submission. This does not claim sub-second push delivery, SMS or email.

Implementation order: database state/audit/notifications and lifecycle bypass → authenticated API → web queue/alert and targeted dispatch handoff → SQL/API/browser regressions → graph and release notes. Reuse existing roles, notifications, React Query, dialogs, BFF session transport and dispatch operations. No new runtime dependencies or deployment are authorized by this local task.

Verify with the actual SQL in PGlite, permission/idempotency/clock regression tests, API tests and browser interactions at desktop/mobile widths. Full Supabase/PostGIS integration, concurrent dispatch/review transactions, production delivery and deployment remain live checks.

## API and dispatch consistency

- `GET /api/reports/urgent-queue?status=pending|approved|declined&limit=1..100` returns oldest-first bounded requests and a total. The web requests 50. Queue rows expose review/dispatch state without citizen identity.
- `POST /api/reports/:id/urgency` accepts `outcome`, required `reason` (3–1000 trimmed characters), `operation_id` UUID and nullable `expected_decision_id`. Actor comes from the authenticated session. Only current officer/admin roles can decide. Database role permissions exclude browser clients.
- Decision history uses an append-only ledger and monotonic sequence. Matching operation retries compare the canonical payload and do not append another decision. A stale expected decision returns HTTP 409; changed decisions require a refreshed queue.
- Approval records the report's title, description, location, issue type, severity, validation, consent and hazard context. Material changes stop the bypass until re-verification. Existing SLA and historical timestamps remain intact.
- Standard/sweeper plans filter explicit report/cluster IDs before the 200-candidate bound. Their server-derived settings snapshot captures approval IDs. Mixed plans obtain the same approval map in the database snapshot. Assignment rejects an old approval, even if it was declined and approved again. Capacity, qualification and commit checks remain in the existing dispatch system.
- Notification receipts have a unique `(report_id, recipient_id)` key. Notification insertion and report submission share a transaction: a failure rolls both back. Polling is shared by query key, session scoped, and paused in background tabs.

## Local verification and release boundary (28 October 2026)

13 actual-migration PGlite tests pass, including role privileges, immutable decision fields, retry conflicts, atomic notifications, unchanged SLA clocks, clearance changes and stale assignment snapshots. PGlite uses a minimal fixture and one connection, so it does not demonstrate production RLS/PostGIS compatibility or multi-connection locking behavior. The existing Mixed SQL body is stubbed in this fixture; its new wrapper runs as written.

42 focused Jest tests pass across PDT-01/PDT-02 API regressions and PDT-03 queue/API/planner tests. Two web unit tests cover clearance and focused handoff. A mocked-BFF Chromium regression passes at 1440px/light and 320px/dark, covering required reason, retained failure draft, identical retry operation ID, queue refresh, dispatch preparation and navigation to existing plan review. Screenshots were inspected for overflow and layout. The changed web files pass ESLint. Browser fixtures do not prove live dispatch execution.

Deployment is outstanding. Apply existing lifecycle/outlier-retirement migrations and PDT-01/PDT-02 first, then `20261029010000_officer_urgent_verification.sql`, then deploy API and web together. Before release, use a staging Supabase/PostGIS database to verify the full schema, backfill/notifications, real two-session review-vs-dispatch races, role demotion, offline urgent sync with the trust gate, and a same-day approved urgent dispatch. Review production notification volume before backfilling existing urgent reports. Roll back web/API first if needed; retain decision history rather than dropping audit data.

The requested manual second opinion is prepared in `manual-gemini-urgency-review.md`; preparing it does not mean Gemini has reviewed or approved PDT-03.

## Gemini review reconciliation (29 October 2026)

See `gemini-urgency-review-triage.md` for every finding and its disposition. Confirmed fixes cover per-group commit isolation, invalidated approvals in Pending, actionable-only backfill/notifications, cluster readiness, superseded retries and explicit dialog conflict recovery with draft retention. Lifecycle activation and self-review are reflected in the UI. Retained first maturation/breach history and closure-time breach capture are intentional; lifecycle_state controls current eligibility. Validation now includes 22 PDT-03 SQL tests, the actual Standard/Sweeper commit function, 42 focused Jest regressions, 3 web unit tests and desktop/narrow Chromium conflict recovery. No live deployment has occurred. The manual review packet remains a historical pre-fix snapshot.
