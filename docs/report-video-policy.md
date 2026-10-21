# Report video submission policy

Updated 21 October 2026. Video-limit migration applied and recorded in the configured backend Supabase project; running local backend confirmed restarted after the fix. Physical-device acceptance remains pending.

## Accepted behavior

Every submitted video must be at least 5 seconds. Administrators choose a whole-number maximum from 5 through 10 seconds. The value is stored as `public.system_settings.report_video_max_seconds` (smallint, non-null, default 10, check 5–10). Neither app constants nor a client-supplied duration decides server acceptance.

The Flutter reporting flow offers camera video recording only. Gallery photo selection is unchanged. Removing gallery video was the user-approved alternative to implementing a gallery-video priority warning; this change makes no new capture-origin attestation or priority claim.

Native System settings and web Admin > Settings > Security expose Maximum video duration. Both send the same field through the existing administrator-only settings endpoint. Historical saves left ten settings rows. Video-policy and admin paths consistently choose the most recently updated row, with creation time and ID as deterministic tie-breakers. Admin saves without an ID reuse that row; stale IDs receive 409 rather than overwriting another saved configuration. Historical rows are retained. The web keeps the selected settings row ID for subsequent updates. The backend rejects non-integers/out-of-range values before saving CMS or system changes.

## Request and enforcement path

- `GET /api/reports/media-policy` requires authentication and the existing suspension check. It returns only `{min_seconds: 5, max_seconds: <saved value>}` with `Cache-Control: no-store`, not other system/security settings. It is registered before the dynamic report-ID route.
- The app loads limits on entering media selection, refreshes them before opening the camera, sets the recorder maximum, and validates actual player metadata without truncating fractions. It refreshes limits again at submission. If the maximum tightens, the report draft and selected media remain available for correction.
- If policy loading fails, recording is disabled with retry and a photo alternative. The app does not invent a cached/default limit to accept video while the database is unavailable. Photo-only reporting remains available; a new video submission requires access to current limits.
- After multipart parsing, the backend checks actual bytes using FFprobe before report creation, evidence upload, or offline media sync proceeds. It requires a supported container and a video stream, rejects corrupt/renamed-audio files, and compares the full numeric duration against the saved bounds, with a maximum-only 100ms allowance for recorder/container stop-time overhead. The 5-second minimum remains strict; the camera is still configured with the administrator's nominal maximum. Thus 10.026s and 10.100s are accepted at a 10s maximum, while 10.101s and longer are rejected. The app uses the same allowance during selection and submission; no duration truncation or extra database setting is used. A spoofed duration field cannot bypass this check. Existing upload size/MIME/extension checks remain.
- Invalid video returns 422. Unavailable settings returns 503. AI content review happens after valid-duration media is accepted; duration validation is distinct from environmental-content approval.

## AI validation corrections

Frame extraction samples 0%, 20%, 40%, 60%, and 80%. Sampling 99% could land after the last encoded frame and fail a valid short clip. Frame commands now have timeouts and explicit JPEG pixel format.

Frame classification preserves the classifier's explicit decision and environmental category. Aggregation respects manual-review/unknown decisions rather than approving them from binary VALID alone, respects explicit rejection, and selects the real category when allowlisted. Existing approval ratios/confidence thresholds and server lifecycle values remain unchanged. Failed inference remains manual review, not automatic approval.

## Migration and rollout

Migration: `migrations/20261021060436_report_video_duration_limit.sql`; matching rollback in `migrations/rollback/`. For additional environments, apply the reviewed migration through the established migration-tracking process before deploying the updated server/app. Do not use `supabase db push` against an incomplete historical schema directory. On 21 October 2026, migration `20261021060436` was applied atomically and recorded in `supabase_migrations.schema_migrations` in the configured project (`wcruoyygungqxazdwhtv`). The schema cache was refreshed. Verification found all ten historical settings rows retained, all video maxima valid, and exactly one migration record. The live-database policy handler returned HTTP 200 with minimum 5 and maximum 10; the running backend had already restarted after the code changes. No administrator-selected pre-existing video value was overwritten because the column did not previously exist.

No RLS, grants, authorization, or existing settings values are widened/rewritten. Existing settings rows acquire the default 10; an administrator can then save 5–10. Rolling back removes this column and requires reverting the dependent app/server behavior too.

The schema follows [Supabase table guidance](https://supabase.com/docs/guides/database/tables); existing settings authorization remains authoritative.

## Verification

- Backend `tests/report-video-policy.test.js`: real synthetic MP4 files at 4.9, 5, 7, 8, 8.1, 10, and 10.1 seconds, changing database maximum, unavailable policy, spoofed duration, corrupt/audio-only media, actual five-JPEG extraction, and AI aggregation outcomes.
- Backend `tests/video-frame-classifier.test.js`: decision/category forwarding, failed inference, and missing input.
- `tests/sql/report-video-policy-regression.sql`: transaction-scoped copied-table checks using the actual defaults/constraints; no live records are modified. Migration/default/bounds/unrelated-setting preservation/rollback also checked in local PGlite.
- Flutter create-report, local-media, admin-settings, and admin-API contract suites: saved limit, fractional/minimum checks, camera-only selection, failure/retry, retained draft after a tightened maximum, range validation, saving/loading, metadata cleanup, and playback.
- Web `tests/system-settings.browser.cjs`: synthetic saved value, edited value in PATCH, failed-save retention/retry, both themes, keyboard tabs, and responsive layouts. Page lint passes.
- One nearby evidence-batching test fails identically on the unchanged committed backend (`anonymous viewers retain the single public query and exact-location restriction`, expects two resource calls and receives four). It is not caused by this patch and remains unresolved here.

Live ML-service classification accuracy, Cloudinary delivery, Android camera/microphone behavior and recorder timing, TalkBack, and end-to-end device capture are not verified by these synthetic checks. Database migration/application was separately verified against the configured live project.

## Startup and settings-read correction

The persistent retry failure had two database causes: the video-limit column had not been applied, and the policy used `.single()` against ten historical settings rows. Both are now resolved without deleting settings. The shared latest-row helper is used by the video-policy and admin read/write paths; it does not claim to migrate unrelated settings readers.

A separate startup failure came from `contact.controller.js` invoking the configured `rateLimiter` middleware with a configuration object during module import. This produced undefined request IP/app/headers and `next is not a function`. Contact throttling is now created with the actual factory in the middleware owner and attached once as its own contact limiter. General/auth/operational limits and validation remain enabled. A real-HTTP test verifies three handled contact requests, a fourth blocked at 429, no startup errors, and no email sends.

Follow-up verification: 23 backend checks pass across video policy, latest-row admin settings, contact startup/limiting, and existing tiered limiting. Live reads confirmed the 5–10 policy, the latest settings selection, preservation of all historical rows, and recorded migration. The local policy route still requires authentication (anonymous request returns 401).

Recording timing follow-up: a reported 10.026-second clip reproduced the app's strict-boundary rejection. The app and server now allow up to 100ms above the configured nominal maximum. Nineteen backend checks include real 10.026s/10.1s acceptance and 10.2s rejection; Flutter boundary checks cover 5/8/10-second settings and exact 100/101ms edges. No schema migration is needed for this calibration.
