# PDT-15 — Live operations and connection indicators

Implemented locally. Hosted schema/API/web deployment and an updated crew mobile build are still required.

## User-visible behavior

The officer Command Center has Overview and Operations feed tabs. The feed reads task transitions and operational milestones from the append-only journal, showing event time, server receipt time, task link, latest update timestamp and older-event pages. New activity is not inferred from generic updated_at fields. Arrival times remain device-reported where appropriate; delayed/offline receipts retain their original time and server receipt time.

Foreground web polling is every 20 seconds with an eight-second request deadline and no automatic retry chain, leaving a normal completed request cycle within 30 seconds. Failed refreshes retain the last successful page with an unavailable warning. Browser offline is a separate state. A snapshot or last successful receipt older than 30 seconds becomes stale even when no request fails; clock changes/future-clock mismatch are explicit. Browser background timer throttling cannot guarantee polling while the tab/device is suspended; focus/visibility refresh and the age check prevent presenting old data as live. No events in a valid snapshot is different from a failed/unavailable feed.

Crew teams show recently connected, no recent contact and unknown member counts, plus latest member contact time. Global counts use distinct nonsuspended field-crew accounts; team membership may overlap. An unrostered bucket preserves staff absent from team membership. No recent contact means no heartbeat within 90 seconds: it may mean lost connectivity, paused sync, a closed/backgrounded app or off shift. Unknown means no heartbeat has been recorded. These are contact hints, not attendance, GPS presence or completion evidence.

## Sources and access

Migration `20261030040000_live_operations_feed.sql` requires PDT-14's journal and the canonical profiles/cleanup_tasks/field_crews schema. Actual task inserts/status changes append task_transition events with from/to statuses and existing authenticated writer attribution. Same-status updates produce no extra event. Existing milestone writers and duration semantics remain unchanged. A partial index supports newest-first task-event reads. The shared web audit/case validators now recognize the added event type.

`GET /api/operational-events/live?limit=20&before_id=...` binds the authenticated nonsuspended officer/admin actor and reads one PostgreSQL snapshot. It uses bigint-safe descending keyset pagination, exact connection counts, a global newest task event reference and an explicit version. Cursor/limit checks apply at API and SQL boundaries. Feed events expose only task reference, event type, safe status/evidence-slot/disposition fields and timestamps. Crew summaries expose team names/IDs and aggregate contact counts, never individual account IDs/names, reporter identities, photos, raw offline evidence or contact information. The roster capacity is 500 teams plus the optional unrostered bucket; an oversized roster errors instead of truncating it.

`POST /api/fc/presence` accepts only authenticated field crew. It ignores supplied identity/clock data, independently checks role/suspension in SQL and records server time. Presence is private, RLS enabled and service-only. Repeated calls inside 20 seconds avoid unnecessary writes. Desk users, citizens and direct anon/authenticated RPC/table access cannot forge crew presence. Presence is not added to public report payloads.

## Mobile lifecycle

The crew shell owns an auto-disposed heartbeat provider, scoped to the current verified field-crew profile/session. It sends immediately and each 30 seconds while foregrounded, pauses in background, resumes on return, prevents overlapping requests and cancels on session disposal. Requests are owner-bound, have an eight-second cancellation deadline, and do not enter the offline outbox. Existing automatic-sync policy and network preferences are respected: manual/offline-only modes or blocked networks can produce no recent contact. Non-crew profiles do not initialize a heartbeat API client. Old mobile builds correctly remain unknown; online status is never inferred from old task updates.

## Rollout and limits

Deploy compatible web readers first, so the new journal event type is accepted before enabling its database trigger. Then apply the migration and deploy the backend and crew mobile build. No additional scheduler/Realtime subscription is needed. Verify a real foreground crew device, loss of signal, background/resume, session change, and officer recovery after network failure. Keep the reader's task_transition support during rollback because historical events remain valid. Do not delete or rewrite the journal.

Local acceptance uses the actual SQL under PGlite, mocked API boundary tests, Flutter lifecycle/provider tests, shared audit/case reader regressions and Chromium across desktop/tablet/phone. A real timed browser test observed automatic refresh within 30 seconds. Hosted RLS/schema, multi-device network behavior, physical devices, mobile release installation and production query plans remain unverified.

## Separate existing preview failure

The broader crew dashboard preview has eight failures at 2× text size: existing `fc_metrics_header.dart` rows (lines 46 and 94) overflow horizontally. The isolated active/light/2× case reproduces it without mounting the crew shell or heartbeat provider. That widget was not changed for PDT-15; the failure is recorded in `.tmp/pdt15-mobile-preview-failure.log`. Heartbeat tests and targeted Flutter analysis pass. This feature does not claim the entire native UI test suite is green.
