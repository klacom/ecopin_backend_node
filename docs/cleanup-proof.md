# PDT-13: cleanup evidence and public proof

Implementation status: locally implemented and regression-tested; coordinated staging/release remains pending. Officer stays web only; Field Crew stays mobile only. No PDT-13 migration or application release has been applied to the hosted environment.

## Workflow

1. Assigned crew collect Before and After photos in task-scoped mobile Report Details. Existing investigation, assignment/version, upload retry and offline sync rules remain active.
2. Physical cleanup requires different Before/After URLs/hashes and action notes. Notes are collected before a report outcome, direct report completion or task completion is queued. Failed sync is not represented as server acceptance.
3. Canonical report resolution records server time and separate `reports.cleanup_action_notes`. This preserves the citizen's existing `reports.notes` explanation. A repeated terminal update cannot rewrite the original completion time. Existing legacy timestamps are not invented or backfilled.
4. New originals uploaded by either crew or officers use the private `Cleanup Originals` bucket. Delivery checks desk role or the current individual/team assignment, including team lead/member fallback. Citizens cannot download these originals.
5. Officer Report Details contains Cleanup proof verification. Load both originals, verify the cleanup, add black masks over faces/plates/names/other sensitive content, write a separate public summary and explicitly confirm privacy review. A public summary is never copied automatically from private staff notes.
6. The server renders separate JPEGs with destructive masks and no copied EXIF metadata. It stores publication ID, source fingerprint, masks, public notes, completion/verification timestamps and private verifier identity. New JPEGs remain in the private `Cleanup Proof` bucket.
7. Public website report details and native citizen report details fetch the approved publication. The media endpoint rechecks the existing public report approval/consent projection, terminal state and source fingerprint for every read. No original-image fallback is offered. Public responses omit storage paths and verifier identity.

Masks are chosen and verified by a human officer. This is not automatic face detection or a guarantee that a reviewer found every sensitive detail. Reopening/hiding the report or changing source photos/private action notes invalidates the public copy until re-review. Already delivered/downloaded copies cannot be recalled.

## Server invariants and exceptions

- The database guards all new physical resolution paths, including legacy offline status operations and classified task outcomes. Canonical writers carry notes before the report update, avoiding the receipt/task insertion-order race.
- Cleaned receipts must reference this report's uploaded After photos. Identical Before/After files are rejected. Verification is not a claim that GPS or photo content is tamper-proof.
- Historical `contested`/`verification_required` receipts remain preserved with `evidence_verification='unverified'` when their references no longer match current photos. They cannot provide accepted cleanup proof or published action notes. Assignment/actor/observation validation and immutable retry results remain in the existing receipt transaction.
- An acknowledged already-clear-on-arrival observation with verified current After evidence needs no fabricated Before photo. Fresh already-clear claims still require the existing desk verification workflow; they do not automatically earn cleanup credit or resolve an open incident.
- Scouting/acknowledge-only work preserves the existing non-cleanup exception. Administrative rejection/closure is distinct from claiming physical cleanup.
- Completed photos cannot be removed by the officer API or the database photo guard. The API unlinks mutable photo references before deleting storage bytes. Valid replacements/additions can invalidate a publication for review; the existing resolved-report After-upload repair remains available for legacy incomplete evidence.
- Review submission checks both source version/fingerprint and the expected publication ID under the report lock. Two reviewers cannot silently overwrite one another. A failed attempt removes its newly uploaded publication objects. Re-review retains notes/masks only while the source matches and requires renewed privacy confirmation.
- No runtime dependency was added. Image rendering is limited to one image at a time per API process with retryable 503 responses, 10 MB input/storage limits and a 20 MP decoded-image review limit. This is not a production concurrency/load benchmark; evaluate large-image native memory use on staging.

## Privacy boundaries

The publication table and review/read RPCs are service-role only with RLS enabled. Both new buckets are private and have no direct anon/authenticated object policies. The backend public route is the only publication delivery path.

Column revokes alone do not protect a new field when a table-wide grant exists. Migration 1 converts any anon/authenticated table-wide SELECT/UPDATE grant into grants for the pre-existing columns, excluding `cleanup_action_notes`. It preserves prior column access but intentionally makes raw `SELECT *` including the private field fail. Use the existing allowlisted public/operational projections and APIs. The global service-role JSON boundary also removes this field for citizens, crew and anonymous viewers, including nested replay/error snapshots; desk review uses its separately authorized source endpoint.

A read-only hosted catalog audit on 29 October 2026 confirmed authenticated table-wide report SELECT exists and that existing Storage read policies name only their older buckets. Tests cover that legacy table-grant case locally. This audit did not create the new buckets or certify their deployed policies.

Legacy Cloudinary originals are not retroactively privatized by this change. A trusted, existing Cloudinary source can be reviewed to generate a safe public copy, but previously exposed external URLs remain a separate migration/remediation task. No bulk photo transfer, deletion or legacy report relabeling occurred.

## Gemini reconciliation

| Finding | Resolution |
| --- | --- |
| Direct resolution bypasses notes/time | Database resolution guard plus direct API validation; all canonical SQL writers store dedicated cleanup notes atomically and server time is set once. |
| Team crew can upload but not view originals | Delivery now mirrors individual/team lead/member assignment checks. |
| Historical receipts rejected against current photos | Non-applied observations remain explicitly unverified; accepted current receipts still require bound evidence. Actual receipt/replay integration tests cover reassignment. |
| Already-clear task cannot finish without Before | Narrow exception for acknowledged, verified arrival observations; pending/contested observations cannot create cleanup credit. |
| Completed photo deletion bypass | API rejects before storage deletion; database checks photo fields as well as status. |
| Uppercase report UUID publication fails | Publication paths use canonical database report IDs in lowercase. |
| Concurrent review clobbers | Expected publication ID is checked under lock in addition to source version/fingerprint. |
| Contested notes presented as cleanup notes | Source uses canonical cleanup notes or applied cleanup receipts only. |
| Re-review loses notes/masks | Persist and restore both for the same source; privacy confirmation is reset. |
| Static review labels privacy/times “verified clean” | Treat as a static assessment, not live release evidence. Public metadata/media remain independently guarded and staging verification is required. |

The manual review prompt is retained as the pre-reconciliation snapshot in `docs/manual-gemini-cleanup-proof-review.md`; it is not the final implementation contract.

## Verification and rollout

Verification evidence is recorded in root `UI_UPDATE_BACKLOG.md`. Targeted database tests execute the actual historical receipt/task/offline SQL function bodies plus these migrations, covering ordering, immutable replay, missing/duplicate/unrelated photos, notes, permissions, time preservation, already-clear observations, source changes and publication CAS. Pixel/metadata tests confirm the public image is a rendered JPEG with the covered region removed and the original metadata absent. Officer Chromium fixtures exercise privacy confirmation, mask editing, stale submission/retry, re-review and public proof at 1440/light, 768/dark and 320/dark.

Release together after staging rehearsal:

1. Back up and verify the intended database schema/function versions. The patches deliberately abort if canonical function text differs from the reviewed source.
2. Apply in order: `20261029140000_require_cleanup_proof.sql`, `20261029141000_cleanup_proof_review.sql`, `20261029142000_cleanup_completion_writers.sql`. Keep completion writes paused until all three are installed and the compatible backend is active; mixed versions can reject valid work.
3. Release the compatible API, website and mobile APK. Old clients missing required notes or private-reference support must not be used for evaluator completion. Preserve pending device work and resolve held/legacy blank-note receipts deliberately; do not fabricate notes or drop offline records.
4. Verify actual Supabase/PostgREST grants, RLS, Storage direct denial and authenticated media delivery with Citizen, Officer, assigned/unassigned Crew and anonymous sessions. Exercise one actual before/after upload, offline receipt, task completion, privacy review and public image read, then hide/reopen the report and confirm delivery stops.
5. Check a physical Android device, real camera/GPS/permissions, network interruption and large images. The current tests do not establish a physical-device or hosted end-to-end pass.

No live deployment, commit or push was performed for PDT-13.
