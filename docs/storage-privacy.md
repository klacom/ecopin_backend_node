# Private Storage read authority

Apply `20261012130000` before `20261012150000`. All three sensitive buckets remain private; avatars remain public. The second migration closes shared-task read gaps in the first helper.

Cleanup Task Photos: staff may read; crew require a ready active task and current explicit assignment. Citizens require at least one canonically attached report and ownership of every canonically attached report. Historical report_ids arrays grant no access. Report Cleanup: owners may read their own report's media; crew require canonical report-to-task linkage, current assignment, and a ready active task. Staff may read historical media. These read rules are distinct from upload/delete rules.

Verification: `node scripts/test-real-storage-http-integration.mjs` runs against the private local Supabase stack with real image bytes, actual Auth JWTs and Storage HTTP requests. Nineteen checks pass, including mixed ownership, stale advisory arrays, inactive/unready tasks, reassignment, foreign-user denial, and assigned-user upload/delete. Signed links are redacted. Test cleanup removes image bytes, report receipts, reports, tasks and users. Additional buckets, complete overwrite permissions, and private client delivery remain separate gates.

Rollback is intentionally fail-closed: it disables cleanup-media reads until the corrected migration is reapplied. It never makes buckets public or restores the known overbroad helper. Byte contents and object metadata are preserved.