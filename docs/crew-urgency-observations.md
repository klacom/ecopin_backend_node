# PDT-04: crew on-site urgency observations

Contract (29 October 2026): assigned crew can record Urgency observed / Conditions differ / Unable to verify, with required observed conditions and existing report Before/After evidence. Observations are evidence, not fraud findings. They do not change trust, urgency approval, report validation or completion. Officer/admin review is a separate explicit action; any punitive trust finding remains a deliberate officer/admin transaction.

Implement in the task-scoped crew report detail used by completion, reusing additive offline notes (`fc.note.add`), the existing photo flow and sync gate. The payload binds the captured task ID, observed result and notes. Submission saves locally first; wording distinguishes saved/queued from acknowledged. A server receipt is idempotent across retries; reassignment, inactive task, route readiness, role and self-review checks remain server authoritative. Normal completion never requires an urgency assessment.

The backend wraps the existing note dispatcher, preserving ordinary operations, its receipt identity and locking. A successful structured observation also stores an immutable observation row, snapshots available Before/After evidence, and atomically alerts officer/admin recipients. Pending/recorded observations can be fetched by report; assigned crew can see their own acknowledged entries, desk roles can review. Marking an observation reviewed requires a reason, a unique retry ID and cannot change citizen trust. Current officers/admins only may make direct trust decisions; replace the old crew trust panel.

Slices: (1) SQL and role/idempotency/no-score tests; (2) authenticated read/review API; (3) offline crew form + officer review panel; (4) regression checks, documentation and graph refresh. No deployment or physical device acceptance is implied.

## Implemented API and persistence

Migration: `20261029030000_crew_urgency_observations.sql`. It moves the existing canonical `apply_fc_operation` into `workflow_private` and wraps only structured `fc.note.add` requests. The legacy implementation still owns ordinary operation validation, operation-ID serialization, canonical request receipts and task/report locking. Observation insertion and notifications share that transaction. No new outbox operation enum or runtime dependency is needed.

A structured note contains `urgency_observation: {task_id, observer_id, assignment_generation, report_claim_generation, result, conditions}`. Results are `urgent_observed`, `conditions_differ`, or `unable_to_verify`; trimmed conditions require 3–1500 characters. The observer is bound to the signed-in account, and both assignment generations must match the current ready, active, person-assigned task. Unsupported/unassigned/self/nonurgent observations fail without leaving a note, receipt or notification. Identical accepted retries remain safe after task completion; new submissions after completion are rejected and remain in the local failure flow.

The server generates the human-readable activity note rather than trusting the client's display text. Observations and reviews use append-only, service-only RLS tables; clients have no direct table/RPC privileges. Evidence snapshots preserve the available Before/After photo metadata and legacy photo URLs at server acceptance time. These are references, not additional copies of image files. Pending uploads may arrive later and deleted media may become unavailable; officers also inspect the report's existing evidence. Recorded time is server acceptance time, not a claim of verified on-site GPS/time.

- `GET /api/reports/:id/urgency-observations`: current staff roles; desk roles read the report's bounded history, crew read their own acknowledged records. Returns up to 50 latest observations, available photo snapshot and review reason/time, without citizen identity.
- `POST /api/reports/:id/urgency-observations/:observationId/review`: officer/admin only, body `{reason, operation_id}`. Requires a reason, rejects self-review and conflicting repeated reviews. Canonical retries reuse the saved review. This action never scores or approves/rejects urgency.
- Citizen trust read/write routes and the database authorization helper now require desk roles. This deliberately supersedes PDT-02's earlier direct-crew-review policy. Existing trust history remains retained; existing admin correction mechanisms remain available. Any trust finding is a separate explicit SWMO transaction, never derived from a crew result or task completion.

## Native interaction and offline behavior

The assigned-task report detail used alongside completion shows the observation form for submitted Urgent reports. It replaces the crew's punitive trust panel. Required result/conditions save through the existing local note cache, additive outbox, sync mode and retry flow. Failed saves retain the draft; saving does not claim officer acknowledgement. Observations remain optional for ordinary completion. Server-side assignment/role checks govern sync even if a local receipt is stale.

Officer native Report Details displays observations before the separate trust panel, allows opening recorded evidence in the existing private in-app image viewer, and requires a reason to mark reviewed. Failed review requests retain the reason and operation UUID; refreshing exposes another officer's already-saved review. Marking reviewed does not auto-select a trust finding. Offline report/task models and staff downloads retain priority, route state and assignment receipts.

## Verification (29 October 2026)

11 actual-migration PGlite tests pass, using the actual canonical sync body, actual person-scoped task authority and PDT-02 trust implementation. They cover no scoring on observation/review, separate officer penalties, role/assignment/account binding, idempotency, immutable history, evidence snapshots, nonurgent/invalid input, completion retries and transaction rollback on notification failure. Simplified schema/one connection does not prove production integration or concurrent transaction behavior.

54 focused Jest tests pass across the new API/download regressions and previous priority/trust/urgent API/planner coverage. 41 previous SQL regressions pass separately; their PDT-02 fixture preserves the historical pre-PDT-04 policy, while the new combined fixture proves the desk-only override.

56 focused Flutter tests pass across the new workflow and existing trust, sync, report outcome and evidence-ordering tests. Six new tests cover DTO/offline receipt persistence, additive retry identity, draft retention, non-scoring officer review, and both crew/officer forms at 320px/2x text in light/dark themes. After account binding, those six were rerun successfully. New/modified domain, form, review, crew detail and notifier sources analyze cleanly. Including the existing API service reveals eight pre-existing brace-style infos; no checks or rules were suppressed.

## Release boundary

No live migration, backend deployment, APK build/release or physical-device acceptance was performed. Apply canonical field sync/person-scoped authority, crew photo collections and PDT-01/PDT-02 prerequisites before this migration, then deploy the new API and app together. Deploy schema/backend before releasing the client: older sync code treats notes as generic activity and does not create the structured officer-review record.

Before release, validate full Supabase schema/grants, reassignments/account changes with pending local work, actual image viewing, automatic/manual/offline modes, notification delivery and concurrent sync/review on real devices. Record role policy change in the presentation: crew supply conditions/evidence; only officers/admins can make direct citizen trust decisions. Existing historical crew decisions are not silently rewritten.
