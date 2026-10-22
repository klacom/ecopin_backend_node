# Batch report evidence authorization

Authenticated `POST /api/reports/batch-evidence` requests now make one Supabase authorization RPC for up to 100 reports, replacing up to 100 individual HTTP calls. Authorization still runs before reading the shared evidence cache. Anonymous requests retain their single `public_reports` query.

The service-only `read_authorized_report_evidence_ids(actor, report_ids)` function returns eligible IDs. It reuses `read_authorized_report_detail` for owner, officer/admin, and active assigned-crew access; otherwise, only exact-location rows from `public_reports` qualify. The database's current permissions remain authoritative. Invalid report UUIDs are omitted before the RPC. Database errors propagate through the normal error handler without serving evidence or falling back to individual calls.

This reduces HTTP requests, not the number of per-report checks inside PostgreSQL. Cloudinary fetches for uncached authorized reports retain their current behavior.

## Rollout and rollback

1. Apply `migrations/20261020062209_batch_report_evidence_authorization.sql` in a transaction before deploying the backend. Confirm the RPC is visible in the PostgREST schema cache.
2. Deploy the backend and verify a logged-in 100-report evidence request produces one `read_authorized_report_evidence_ids` HTTP call. Check a private report as its owner and as an unrelated citizen.
3. To roll back, restore the prior backend first, then apply `migrations/rollback/20261020062209_batch_report_evidence_authorization.sql`. The previous single-report RPC is unchanged.

The backend must not be deployed ahead of the migration: a missing RPC causes evidence requests to fail closed.

## Validation

- `npm test -- --runInBand tests/report-evidence-batching.test.js` covers the request count, per-viewer cache checks, denied IDs, UUID validation/case, the 100-ID cap, errors, and anonymous access.
- `npm run test:db:public-access` runs the existing projection/detail contracts plus 16 batch-access contracts and migration up/down/up in an isolated PostGIS container.
- With Docker unavailable in this session, the actual detail and batch function SQL was executed in temporary PGlite PostgreSQL using synthetic tables and a public projection fixture. All 16 contracts passed before and after rollback/reapply; direct anonymous/authenticated execution was denied, service-role execution succeeded, and 101 eligible IDs were capped at 100. This does not verify the full PostGIS schema, hosted PostgREST, or production deployment.

Supabase supports array arguments for [bulk RPC calls](https://supabase.com/docs/reference/javascript/rpc). Function execution privileges follow the [database functions guidance](https://supabase.com/docs/guides/database/functions).
