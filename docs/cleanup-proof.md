# PDT-13: cleanup evidence and public proof

### Several Before/After photos — 2 November 2026

Field crew can attach up to 5 photos to each slot (`reports.before_photos` / `after_photos`, capped by a table check). Cleanup proof now carries all of them end to end. `before_photo_url` / `after_photo_url` remain the first photo of each slot.

**API contract** (the Flutter app already reads it; see `ecopin_app/DESIGN.md`, "Citizen Report Details - answer first"):

| Endpoint | Change |
| --- | --- |
| `GET /api/reports/:id/cleanup-proof/owner` | Adds `before_urls` / `after_urls`, e.g. `/api/reports/:id/cleanup-proof/owner/before/1`. Still `owner_only: true`, no `verified_at`; owner photos are never presented as officer-reviewed. `before_url` / `after_url` keep returning the first photo. |
| `GET /api/reports/:id/cleanup-proof/public` | Adds `before_urls` / `after_urls`, e.g. `/api/reports/:id/cleanup-proof/public/<proofId>/after/2`, one per reviewed copy. Storage paths are never returned. |
| `GET .../owner/:slot/:index`, `.../public/:proofId/:slot/:index`, `.../original/:slot/:index` | New image routes. The `/:slot` forms still work and serve index 0. Authorization is unchanged: owner routes need the report owner, public routes need the current approved publication, `original` routes need a desk role. |
| `POST /api/reports/:id/cleanup-proof` | `redactions` is now per photo. |

Index rules: `index` is a zero-based integer without a leading zero and at most two digits (`/^(0|[1-9]\d?)$/`). Malformed values return 400 before any lookup; authorization runs next (a caller who may not see the report gets the usual 404/401 regardless of index); an index past the number of photos returns 404 without touching storage. Lists never exceed 5 items even if a source holds more.

**Review.** Staff review (`CleanupProofReview`) opens one editor per photo with its own hidden areas, and approval requires every original to load and the privacy confirmation. The request sends `redactions: {before: [[rects…], …], after: […]}` in photo order. The server renders each photo with only its own rectangles, uploads each JPEG to `Cleanup Proof`, and publishes all copies in one RPC. If any render, upload or RPC step fails, every newly stored copy is removed. A request whose rectangle lists do not match the source photo count is rejected with 400 before any storage work. For compatibility a single-photo report may still send (and is stored with) the flat `before: [rects…]` form; a flat list for a multi-photo slot is rejected rather than guessed.

**Database** (`migrations/20261102120000_cleanup_proof_multiple_photos.sql`, rollback in `migrations/rollback/`):

- `cleanup_proof_publications.before_paths` / `after_paths` (jsonb arrays, 1–5 items, first item must equal `before_path` / `after_path`). Existing rows keep `NULL` and read as a one-item list, so existing publications are unchanged.
- `workflow_private.cleanup_proof_photo_urls(report, slot)` returns the ordered source references (falls back to the single legacy column). The review source gains `before_urls` / `after_urls`.
- `publish_cleanup_proof_photos(...)` requires exactly one reviewed path per source photo, each under this report and slot, no duplicates, with the existing version/fingerprint/publication-id checks. The original `publish_cleanup_proof(...)` signature stays as a one-photo wrapper, so a not-yet-upgraded backend keeps publishing single-photo reports and is refused for multi-photo reports instead of publishing a partial set.
- `read_cleanup_proof` returns `before_paths` / `after_paths`. The source fingerprint is unchanged and already covers the photo collections, so adding, replacing or removing a photo invalidates a publication until every photo is reviewed again, as before.

**Before the migration is applied.** A read-only inspection of the hosted EcoPin project on 2 November 2026 confirmed the three cleanup-proof functions, the fingerprint function and the publication table matched the repository, the publication table was empty, and 493 reports hold more than one photo in a slot (at most 3). The migration was not applied to the hosted database from this change. Apply it before deploying this backend (the new controller calls `publish_cleanup_proof_photos`; a database without the migration returns "Proof could not be approved"). Rolling the backend back first is safe. Deploy the website with the backend: the proxy allowlist and the review screen know the indexed routes.

**Tests.** `tests/cleanup-proof-photos.test.js` (authorization, index bounds, caps, backward-compatible single-photo responses, publish/redaction/cleanup behavior), `tests/cleanup-proof-photos-db.test.mjs` (ordering, one-for-one path validation, legacy signature, invalidation, grants; run with `node --test`), and `ecopin-web/tests/cleanup-proof.test.mjs` (proxy allowlist for indexed routes, review state).

The public website comparison slider (`explore/CleanupComparison`) intentionally shows only the first reviewed photo of each slot; the citizen app and the staff-approved public proof panel show all of them.

### Report-owner access — 2 November 2026

Authenticated report owners use `GET /api/reports/:id/cleanup-proof/owner` and its `/:slot` image route. Both handlers verify ownership through `read_report_identity_context`, including hidden-identity ownership, before reading cleanup sources. The metadata allowlist returns only owner-only image endpoints and completion time, never original URLs, private notes or verifier information. Images are rendered as metadata-free JPEGs with `private, no-store` and `Vary: Authorization`; the general Storage endpoint remains restricted. Public viewers still need the separate reviewed publication.

This fixes the native screen incorrectly treating an unpublished public copy as missing owner evidence. A read-only check of Tambak ng Basura (`59edcb44-5987-423a-afea-48ed28a3848a`, closed, rating 3) exercised the new local handlers against hosted records: both slots returned JPEG bytes without creating a publication. Backend and mobile changes must be released together; no deployment or live-data mutation was performed.

Implementation status: locally implemented and regression-tested. Officer stays web only; Field Crew stays mobile only. A read-only audit on 2 November 2026 confirmed that the hosted EcoPin database has `read_cleanup_proof`, `read_cleanup_proof_source`, `cleanup_proof_publications` and the Cleanup Proof bucket. This corrects the earlier statement that none of this schema was installed; it does not establish that every coordinated migration/client release is complete.

### Read-only fetch audit — 2 November 2026

The backend configured by the citizen app was confirmed to use the audited EcoPin project. The public proof metadata route returned HTTP 200 with `proof: null`, including for a closed report with both legacy photo references. The live publication table, Cleanup Proof objects, and Cleanup Originals objects each contained zero rows. Report photo references alone are not an approved publication. No positive live image-download check was possible without an approved publication; unavailable Before and After publication URLs correctly returned 404. No photos were uploaded, published or changed during this audit.

Focused backend tests cover the matching Before/After storage paths in Cleanup Proof, JPEG delivery, no-store headers, empty metadata, database failure, replaced publications and missing objects without an original-photo fallback. Publication still requires the existing officer verification/privacy workflow; a missing publication must remain an honest empty state.

## Workflow

1. Assigned crew collect Before and After photos in task-scoped mobile Report Details. Existing investigation, assignment/version, upload retry and offline sync rules remain active.
2. Physical cleanup requires different Before/After URLs/hashes and action notes. Notes are collected before a report outcome, direct report completion or task completion is queued. Failed sync is not represented as server acceptance.
3. Canonical report resolution records server time and separate `reports.cleanup_action_notes`. This preserves the citizen's existing `reports.notes` explanation. A repeated terminal update cannot rewrite the original completion time. Existing legacy timestamps are not invented or backfilled.
4. New originals uploaded by either crew or officers use the private `Cleanup Originals` bucket. General Storage delivery checks desk role or the current individual/team assignment, including team lead/member fallback. Report owners view rendered photos only through the separate authenticated owner routes above.
5. Officer Report Details contains Cleanup proof verification. Load both originals, verify the cleanup, add black masks over faces/plates/names/other sensitive content, write a separate public summary and explicitly confirm privacy review. A public summary is never copied automatically from private staff notes.
6. The server renders separate JPEGs with destructive masks and no copied EXIF metadata. It stores publication ID, source fingerprint, masks, public notes, completion/verification timestamps and private verifier identity. New JPEGs remain in the private `Cleanup Proof` bucket.
7. Public website report details and native report details for non-owners fetch the approved publication. The public media endpoint rechecks the existing public report approval/consent projection, terminal state and source fingerprint for every read. No public original-image fallback is offered. Public responses omit storage paths and verifier identity. Native report owners instead use the authenticated owner routes described above.

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
