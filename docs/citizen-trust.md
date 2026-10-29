# PDT-02: citizen trust and Urgent eligibility

Policy approved 28 October 2026: new trust score 50/100, Urgent threshold 70, human-verified valid report +10, proven false urgency -30. Clamp to 0–100. False urgency requires an explicit human finding and reason; ordinary rejection, low severity, AI classification and declined urgency never imply dishonesty.

After a false urgency finding, Urgent remains locked until both seven days have elapsed and three consecutive human-verified valid reports have been recorded after the finding. Time alone earns no points. A neutral human review gives no points and resets an incomplete recovery streak; once three consecutive valid reviews have satisfied recovery, neutral reviews do not revoke that achievement. Another false claim restarts recovery and the seven-day minimum. Reviews use server decision order/time, not report upload time. No historical/AI backfill.

## Implementation plan and acceptance

1. Database: service-only trust state and append-only decision ledger; role/assignment checks; transactional state replay; row-lock Urgent gate for report inserts. Submitted priority and reporter ownership cannot be reassigned after submission; trusted account administration may anonymize a reporter. One effective human decision per report, repeated identical requests are idempotent, conflicting decisions rejected. Admin corrections supersede an existing decision with a new outcome or `withdrawn`, and replay all effective decisions from the initial score in server sequence. Corrections take effect at their new decision time/order, so a newly confirmed false claim starts a new seven-day minimum. Score caps/floors are respected. No self-review or citizen access to mutations.
2. API: authenticated own-trust endpoint; authorized report trust-review read/write; admin reversal. Actor always comes from verified authentication. Errors preserve draft data. Online and sync insert paths cannot bypass the database gate. Ordinary reporting remains available.
3. Mobile: profile displays score, lock/recovery requirements and refresh. Create Report disables Urgent when untrusted or eligibility is unavailable and keeps Non-urgent usable. A previously loaded eligible citizen can save an Urgent draft offline; the server rechecks eligibility on sync. A newly locked queued report remains saved with an error rather than being silently downgraded. An online gate rejection refreshes mobile eligibility and preserves entries. SWMO/assigned crew report details expose explicit human review with mandatory reason, clear false-claim warning, retry/error handling and no offline queue for punitive decisions.
4. Verification: real PostgreSQL migration tests via embedded PGlite (dev dependency only), API permission/contract tests, Flutter eligibility/gate/profile/review tests and existing report-flow regressions. Review concurrency, idempotency, bounds, seven-day equality, multiple false findings, reversals and offline behavior. Update graphify and design/backlog records.

## Structure and conventions

Keep SQL in `migrations/`, server trust helpers/controllers alongside existing services/controllers, tests under `tests/`, and mobile trust models/providers/widgets alongside shared reports/profile. Use existing ES modules, parameterized Supabase RPCs and Flutter/Riverpod controls. No production dependencies, new authentication mechanism, automatic dispatch change or changes to strike/suspension policy.

## API

- `GET /api/reports/trust/me`: current authenticated citizen's score, `urgent_allowed`, `locked_until`, `recovery_reports_remaining`, policy values and server time. No client-selected target. No HTTP caching.
- `GET /api/reports/:id/trust-review`: authorized staff can see submitted priority, reasons and the current decision. Citizen identity is not included in this response.
- `POST /api/reports/:id/trust-review`: `{ "operation_id": "<new UUID>", "outcome": "valid|neutral|false_urgency", "reason": "<3–1000 characters>" }`. Actor comes from authentication. Crew must have a ready, active, assigned task (direct/team membership); decisions lock the task/team membership through commit.
- Administrator correction uses the same POST with `expected_decision_id` set to the current decision ID and an outcome of `valid`, `neutral`, `false_urgency` or `withdrawn`. Use a fresh operation UUID. A retry keeps the same UUID and canonical payload. Changed/reused operation IDs or stale corrections return 409. Native staff screens record the initial review; admin correction is an API operation.
- An Urgent report insert rejected by the gate returns 403 with code `URGENT_TRUST_LOCKED`. Sync returns the code and reason per item. It does not delete the local draft.

Lock order is report → actor/task/team → citizen trust. Race-safe first-use insertion creates one trust row before locking it. The Urgent trigger and review/replay functions lock that same row. Routine updates to an existing urgent report remain available even after its citizen loses eligibility.

Report deletion retains the decision ledger, and administrators can correct retained findings without a live report. Account deletion removes trust state and anonymizes the ledger's citizen/reviewer references; it does not retain an identifying recipient or make a deleted account eligible. This follows the existing account-deletion behavior rather than introducing permanent identity retention. Corrections for deleted accounts have no live trust recipient.

## Release and verification

1. Apply PDT-01's `migrations/add_citizen_report_priority.sql` first if not already applied.
2. Apply `migrations/20261028150000_citizen_trust.sql`.
3. Deploy the API, then the mobile application. Existing accounts start at 50 until explicitly human-reviewed reports earn credit; old AI approvals are not imported.
4. Smoke-test two valid reviews → unlock; proven false urgency → penalty/lock; seven-day boundary plus recovery; ordinary reporting; mobile offline rejection/retry; staff assignment changes; and admin correction.

Local checks:

```text
npm run test:trust:db
npm test -- --runInBand tests/citizen-trust-api.test.js tests/citizen-priority.test.js tests/citizen-priority-sync.test.js tests/report-evidence-batching.test.js
flutter test test/reports/citizen_trust_test.dart test/reports/report_priority_test.dart test/reports/offline_priority_test.dart test/ui/offline_report_receipt_test.dart test/ui/create_report_flow_test.dart test/ui/crew_report_workflow_test.dart test/ui/profile_deletion_roles_test.dart
```

The PostgreSQL tests execute the actual migration in development-only [PGlite](https://pglite.dev/docs/api), including role grants, append-only access, score bounds, human decisions, retries, cooldown/recovery, corrections, deletion and privacy. They use a minimal fixture schema and one database connection; full Supabase/PostGIS integration and simultaneous multi-connection races remain deployment checks. [PostgreSQL row locks](https://www.postgresql.org/docs/current/explicit-locking.html) provide the intended serialization; the local tests do not claim to prove concurrent execution.

Results after Gemini review triage: 19 PostgreSQL tests, 38 Jest tests and 60 Flutter tests across the focused backend/mobile suites. The staff review and confirmation dialog fit 320px with 2× text in light/dark themes. Analysis found no errors/warnings in changed mobile files; existing informational style lints remain. The seven-day cooldown is 168 elapsed hours, including across daylight-saving changes.

Fresh-context review identified correction-after-deletion, owner anonymization and inherited service grants as actionable issues; fixes and regression tests are included. The user subsequently supplied a manual Gemini review. See `gemini-trust-review-triage.md` for verified defects, fixes and intentional policy choices; the original prompt remains a frozen historical snapshot. No production migration/deployment or physical-device validation has been performed.

Profile now offers recovery for owned offline drafts rejected by the Urgent gate: explicit confirmed Non-urgent conversion or eligible Urgent retry. Sync invalidates trust on gate rejection and never uploads evidence while metadata is still blocked. SQLite schema 8 adds owner IDs to reports/media; requests verify the same account before sending. Old records with no owner are retained but quarantined, because assigning them to the next signed-in citizen would expose/submit another account's report. Successful trust status survives screen changes for offline use and is cleared on account changes and explicit refresh/rejection.

## PDT-04 policy amendment (29 October 2026)

PDT-04 supersedes the earlier direct-crew trust-review permission: only officers/admins may now read or record direct citizen trust decisions through these routes/RPCs. Assigned crew submit non-scoring on-site urgency observations via their existing offline note queue, for separate officer review. Observation submission, contrary evidence, marking reviewed and ordinary task completion never automatically change trust. Historical decisions and admin correction rights remain intact. Implementation and current tests: `crew-urgency-observations.md`.
