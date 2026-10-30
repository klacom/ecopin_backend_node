# PDT-23 — Five-day unprocessed incident escalation

Local implementation complete; migration, scheduler activation and hosted verification are pending.

## Policy

The backstop uses authoritative `reports.created_at`, never `updated_at`, the configurable response SLA clock, grouping or a reset on assignment. Amber begins at 96 elapsed hours; red and notification eligibility begin at 120 elapsed hours. Age bands are exact 24-hour periods from submission, independent of Manila calendar midnight.

An open report remains eligible if **either** acknowledgement **or** current crew assignment is missing. Acknowledgement is a recorded acknowledged/responded/in-progress report stage or status, a server-basis report acknowledgement in PDT-14's journal, or linked task work already en route/in progress/partially completed. AI validation alone is not acknowledgement. Assignment requires an existing task in a known active status and a nonempty crew-member list or assigned crew team; a bare task link, stale link, unknown state, cancelled/completed/failed task or empty roster does not satisfy it.

Resolved/completed/closed/awaiting-feedback, rejected, withdrawn and cancelled report states or terminal stages are excluded; rejected validation is also excluded. Missing, non-finite, future or pre-2000 creation clocks cannot produce alerts. Unknown active legacy report statuses remain eligible when the clock is valid.

## Delivery and retries

`escalate_unprocessed_reports()` creates existing `notifications` records for nonsuspended officer/admin profiles. The first notice is “5-day incident escalation”; later age bands produce “Unprocessed incident reminder”. Delivery is deduplicated by report, recipient and elapsed age-day. Skipped days are not replayed as a burst. Newly eligible staff can receive a current-band notice. Reading or deleting a notification does not change the report state or erase delivery history; a corrected, assigned/acknowledged or terminal report leaves the current queue automatically.

A private RLS-enabled delivery ledger and notifications are written in one transaction. Failure leaves no delivery claim and can be retried. Ordered report locks, SKIP LOCKED and the unique ledger handle multiple workers; eligibility is reread after acquiring report locks. Each run handles at most 500 reports, filtering already-delivered recipients before limiting, so subsequent runs advance through the queue. Operational logs expose reports_checked and notifications_created counts and failures; a 500-report run indicates further work may remain. Production-scale latency and multi-connection concurrency still need hosted verification.

Bodies contain a report reference, elapsed days and missing actions. They contain no reporter account link, profile/contact fields, incident title, description, photos or evidence. No messages were sent to live users during local tests.

## Web/API

Authenticated, nonsuspended desk roles can GET `/api/reports/unprocessed-alerts?limit=20&cursorCreated=...&cursorId=...`. Actor identity is taken only from authentication and independently checked in SQL. The private, no-store response has exact current total/overdue/approaching counts and oldest-first keyset pages (1–100 rows), with explicit next cursor and snapshot time. GET does not send notices or mutate data.

The officer Command Center shows red/amber counts. “Review stagnant cases” opens an accessible scrollable dialog with the missing actions, submission date and existing incident-detail link. It supports pagination, empty/loading/error states, stale-data warning, refresh and keyboard focus restoration. The query refreshes each minute while the tab is active and is invalidated by existing dashboard mutations. Displayed timestamps use Asia/Manila. Closing the dialog returns to the first page. Reports still need ordinary officer review and crew coordination; there is no dismiss-to-resolve shortcut.

## Deployment

1. Apply `migrations/20261030030000_unprocessed_report_escalation.sql` after the canonical report/task/notification schema and PDT-14 operational journal. It adds only a private ledger/view and service-only RPCs; it does not broaden table grants or alter public report payloads.
2. Deploy the backend and web changes together.
3. Set `UNPROCESSED_ESCALATION_ENABLED=true` on the backend process and restart. Default cron is `*/15 * * * *` (Asia/Manila), configurable with `UNPROCESSED_ESCALATION_CRON`. The scheduler is independent of `REPORT_LIFECYCLE_ENABLED`. No scheduled notices are sent while this flag is absent/false.
4. Confirm “[UnprocessedEscalation] registered” and successful run counts, then verify an actual five-day report and recipient notification. The dashboard cutoff is exact at refresh; the scheduled delivery is within the next run, subject to batch capacity and uptime. Keep the backend process running.

Rollback: disable the flag/restart to stop delivery. Revert web/backend callers before removing database objects. Leave the private ledger in place if restoring the feature so already-delivered notices are not resent.

## Local verification

The real migration is executed against isolated PGlite, covering thresholds, either missing action, exclusion rules, explicit clocks, journal acknowledgement, real current assignment, staff/grant/suspension checks, retry deduplication, notification failure rollback and batch progress. Jest tests cover actor binding, pagination, unavailable migrations, opt-in cron registration, overlapping local ticks, error recovery and shutdown. Web unit tests reject inconsistent counts, severities, ages and cursors. Chromium scenarios exercise 1440px light, 768px dark and 320px dark, red/amber differentiation, dashboard fit, keyboard dialog, incident links, pages, stale/error/retry and empty states. Hosted schema/RLS execution, production query plans, real delivery timing and external push/email are not verified; this feature writes the existing in-app notification store.

Local results (2026-10-30): eight real-SQL integration cases; 47 Jest suites / 413 cases; 150 web unit cases plus six deadline cases; production build; scoped ESLint; git whitespace checks; all three Chromium alert scenarios passed. A separate 1440×800 desktop check confirmed the added summary does not clip the existing command panels. The PostgreSQL-to-browser microsecond day-boundary tolerance has its own regression case. Graphify was refreshed after code changes.
