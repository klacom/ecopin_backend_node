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

## Hosted rollout and availability repair — 29 October 2026

Applied through the connected Supabase migration tool to the verified EcoPin project `wcruoyygungqxazdwhtv`. The hosted ledger stopped at `20261023125135`; catalog inspection confirmed the priority/trust/urgency dependencies were also absent. The privacy migration is independent of those dependencies and was applied first to restore protected report responses. The remaining dependencies were applied in order. The hosted tool assigns its own versions; match these entries by name when comparing local SQL files, and do not reapply them under their original local timestamps.

| Hosted version | Migration name |
| --- | --- |
| 20261029060307 | anonymous_report_identity |
| 20261029060341 | add_citizen_report_priority |
| 20261029060410 | citizen_trust |
| 20261029060417 | officer_urgent_verification |
| 20261029060424 | crew_urgency_observations |
| 20261029060510 | reconcile_pasig_barangay_boundaries |
| 20261029060517 | barangay_operational_analytics |
| 20261029060523 | hotspot_pattern_history |

Authentication now bypasses report-output scanning only within the exact `/api/auth` namespace, retaining `Cache-Control: no-store`. These routes return the requesting account/session rather than report records. Login, refresh and account lookup therefore remain available during report-metadata outages; similarly prefixed report routes remain protected. Report responses still fail closed when privacy lookup fails. The web proxy preserves an upstream 503 with a generic response instead of changing it to 502 or exposing database details.

Verification:

- 338 backend Jest tests, 99 backend Node tests, 148 web unit/deadline tests and the web production build passed. The two new regression cases failed before the fix and passed afterward. Jest was restricted to `*.test.js`; Node's runner executed `*.test.mjs` separately. The default backend Jest discovery also picks up Node tests and is not a valid combined runner.
- The hosted privacy metadata RPC is callable through PostgREST. Nonempty batch-evidence requests return 200 through both the local backend and local web proxy. A real-account successful login was not exercised; HTTP regression tests cover account-bearing login, refresh and me responses with a deliberately unavailable privacy RPC.
- A synthetic hidden report inside a rolled-back database transaction passed officer raw-row denial, masked operational-view access, owner raw-row access, anonymous raw access denial, private ownership-marker creation and client RPC privilege denial. Confirmed no fixture report remained. The first anonymous check encountered the existing table-level denial; the corrected assertion accepts either table denial or RLS denial without weakening grants.
- Real PostGIS acceptance passed for all 30 polygon interior anchors and boundary points, plus outside/invalid coordinates. Hosted analytics returned 31 groups (30 barangays and unassigned), the hotspot RPC returned 30 zones, and the officer urgency queue executed successfully.
- Security advisors were checked before and after. New no-policy notices concern intentionally server-only tables with client privileges revoked. The new `report_activity_view` notice concerns the documented constrained read-role design; its role checks passed. Existing definer-function and password-protection advisories remain. See [RLS notices](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy) and [definer-view notices](https://supabase.com/docs/guides/database/database-linter?lint=0010_security_definer_view).

No historical barangay backfill or polygon import was performed. All 576 existing reports remain `pending_reconciliation` and correctly aggregate as unassigned until a reviewed backfill. Local code changes still need the normal release/restart on any separately hosted backend/web instances. These checks extend the earlier local evidence; they do not constitute a complete hosted-platform access matrix or independent staging rollout.
