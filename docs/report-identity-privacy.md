# PDT-20: per-report identity protection

Status: locally implemented and final manual review reconciled; ready for staging/platform verification. No live migration or deployment has been performed.

## Behavior and scope

Citizen Create Report has **Hide my identity** on the Review step. An enabled report-level override wins over the existing account-wide `profiles.data_consent` name-disclosure choice. Off follows the existing choice. Public publisher lookup discloses a name only for a publicly visible report, explicit `hide_identity=false` and explicit global consent. It never returns account UUID/email/phone. Hidden reports conceal the reporter from officers, crew and admin output as well as the public. The owner remains privately linked for My reports, notifications, quotas and trust enforcement. Internal authorization runs before output masking; no-self-review still uses the private original owner.

The flag survives offline drafts, blocked urgency recovery/retry, report-model caching and rejected-report prefill. It is immutable on an existing report; the owner may choose a different setting for a newly submitted replacement report. The server-side copy endpoint preserves the original choice. The native queue upgrades Drift v8→v9, with false as the legacy-draft default.

No citizen web Create Report screen was added, consistent with the earlier mobile/shared-API scope. The staff web detail screen honors the override and no longer displays reporter UUIDs. UI hiding is supplementary; database grants/RLS and backend output control are authoritative.

## Database boundary

Migration `20261029032516_anonymous_report_identity.sql` was created using the verified Supabase CLI, then authored locally. It adds `reports.hide_identity boolean NOT NULL DEFAULT false`, immutable flag/owner guards and protected privacy markers. Direct client insertion of a hidden report is rejected; use the protected backend API. Privileged account deletion may null the original owner through the existing FK, while a private marker continues protecting historical material.

A restrictive raw SELECT policy blocks hidden rows from `anon`/`authenticated` except their owner, without broadening any existing permissive access. The existing limited `public_reports` projection remains visible and contains no identity fields. The operational `reports_view` is rebuilt with CASE-masked identity/capture metadata, `security_barrier=true`, and an explicit NOLOGIN/NOINHERIT/NOBYPASSRLS read role. Its source policy checks the real current profile and ownership/crew assignment. A caller-invoker view cannot recover rows that raw caller RLS has denied, which is why this constrained-role design is intentional. See [Supabase views](https://supabase.com/docs/guides/database/views) and [row-level security](https://supabase.com/docs/guides/database/postgres/row-level-security).

`report_activity_view` masks reporter actors and metadata **before** author filters and counts. Staff-originated activity retains its independent attribution. Raw audit records are preserved. A service-only strike projection excludes associations with hidden reports from staff account-level strike queries. Client raw related-table access is restricted; opaque/non-UUID operation log tables are backend-only. Legacy dependent views (including transitive wrappers and column grants) and direct sensitive definer JSON/record RPC grants are retired from client roles; service-role API access remains. Capture/review the affected live catalog before rollout because this intentionally tightens previously exposed interfaces.

Private report and related-record/strike markers survive withdrawal and review-queue deletion. They protect old audit/replay records even when foreign keys set `report_id` to NULL. Markers store UUID links only, not names/emails/phones, and are inaccessible to client roles. Do not purge them while corresponding raw audit, conflict, replay or archive copies still exist. This prevents withdrawal from becoming an identity-disclosure operation.

## Backend boundary and compatibility

The shared API accepts boolean `hide_identity` (and literal multipart `true`/`false`). The old ordinary submission paths remain available. First-party clients use these protected paths whenever identity hiding is requested:

- `POST /api/reports/identity-protected`: same authentication/quota/media checks as normal creation; forces `hide_identity=true` after multipart parsing.
- `POST /api/reports/sync/batch-protected`: accepts a mixed batch using the same strictly parsed per-item flags. A batch containing any hidden draft uses this route.

An older server returns 404 for these paths instead of accepting the report and ignoring its privacy preference. No silent fallback to an ordinary path is allowed. Drain **all** older backend instances before enabling hidden submissions: old staff/read handlers cannot be trusted merely because a newer instance accepted a protected write.

The global API JSON response boundary calls the service-only `read_report_identity_context` in bounded batches, then sanitizes nested report objects, publisher mappings, logs, trust snapshots and stored photo/conflict/replay records before Express emits JSON. It also covers the global error handler. Missing schema/lookup failures return a generic 503 without emitting the original payload. Context lookups include private tombstones for withdrawn reports and orphaned artifacts. Independent staff activity is preserved; the report author and private profile/capture fields are removed. Existing raw stored audit/replay data is not rewritten or made publicly readable. API report reads additionally use a fail-closed local helper when a projection omits privacy state.

Publisher batch lookup first checks `public_reports` eligibility; rejected/unapproved/non-public IDs cannot disclose names. Offline idempotency keys are bound to the authenticated owner, foreign collisions return no original report ID, and retries cannot change the saved privacy setting.

The existing native direct `reports_view` reads remain supported through the secured database projection. The officer map no longer subscribes to raw `reports` CDC: its auto-disposed feed loads all protected-view pages immediately and polls every 15 seconds while subscribed, without overlapping requests or falling back to raw rows. A failed read shows a recoverable error; the next successful poll or Retry restores the map. Citizen public-map and My reports sources are unchanged. Masking occurs before crew caches/offline packages are populated. Client applications contain no service-role credentials.

## Review and verification

Initial manual Gemini review and internal review findings/reconciliation: [triage](gemini-anonymous-reporting-review-triage.md). Final manual implementation prompt: [review artifact](manual-gemini-anonymous-reporting-final-review.md). The returned review approved staging after an officer-map feed repair; that repair and the plural-ID improvement are now implemented and tested.

Verified locally:

- Backend: 338 Jest tests and 98 Node/database/HTTP tests pass. Focused privacy tests cover RLS despite permissive policies, flag/owner immutability, public visibility, staff and assigned-crew visibility, legacy definer views/column grants/RPCs, varchar sweeper-log compatibility, query-time log/strike count protection, queue-first withdrawal, FK-nullified audits, service-only context and nested response/error masking. Existing trust/self-review tests continue passing.
- Mobile: 35 focused widget/transport/offline/flow tests pass, including light/dark 320px toggle layout, offline/retry retention, rejected-report prefill, protected route selection, masked-view feed pagination/recovery/disposal and hidden officer-map markers in both themes.
- Web: 177 unit/deadline tests and production build pass. Chromium checks pass for 1440px light/officer and 320px dark/admin: normal global name disclosure remains available, the per-report override suppresses it even with consent true, no reporter UUID is rendered, and no horizontal overflow/runtime error occurs. The browser fixture intentionally includes raw identity to test the UI defense; actual API privacy is tested independently.

Scoped web ESLint reports two pre-existing `no-console` errors in the detail page’s video-playback code (lines 79/81), outside the PDT-20 diff. No suppression or unrelated playback change was made.

Commands: backend `npm test`; focused `node --test --test-isolation=none tests/report-identity-db.test.mjs tests/report-identity.test.mjs tests/report-identity-http.test.mjs`; native `flutter test test/reports/officer_map_privacy_test.dart test/reports/officer_report_feed_test.dart test/reports/report_identity_transport_test.dart test/reports/report_identity_test.dart test/reports/offline_priority_test.dart test/ui/create_report_flow_test.dart`; web `npm test`, `npm run build`, and `node tests/report-identity.browser.cjs` with the existing Playwright/Chromium environment paths.

## Deployment prerequisites and limits

1. Final manual review is reconciled. Restore a disposable copy of the intended schema/catalog, inspect the migration's affected grants/functions/views, and run the complete migration and access matrix against actual PostgreSQL/PostGIS/PostgREST. Local Docker is unavailable, so this platform check and live Supabase advisors remain unverified. PGlite role tests are evidence for the tested PostgreSQL mechanics, not a complete hosted-platform audit.
2. Apply the migration transaction to the intended database using the established reviewed rollout procedure. Keep `privacy_private` out of exposed Data API schemas. Verify client cannot read its tables; verify public visibility, owner edits/account deletion, staff/crew operational reads, related-table filters/counts, nested photo/conflict/replay responses and no-self-review. No production write was performed during implementation.
3. Deploy/restart every backend instance containing the response boundary and protected routes; drain older instances. Missing database setup must remain unavailable, never return raw records. Then release mobile/web updates. Exercise online, offline/retry and rejected-report paths with synthetic accounts before real use.

This is authenticated pseudonymous reporting at the app/role boundary. User-written text/photos, incident location/time, existing copies, operators with server/database secrets, backups and infrastructure consoles can still identify or correlate someone. The toggle explicitly warns that text/photos remain visible. This work does not certify legal compliance or guarantee complete whistleblower protection.
