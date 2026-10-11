# Verification token and cron history retention

Migration `20261011163533_enforce_verification_token_and_cron_history_retention`, verified 12 October 2026 Asia/Manila.

## Problem and policy

Verification rows and pg_cron history previously grew unbounded with no automated scheduled retention cleanup.

A conservative, safe 30-day retention policy is established:
1. `email_verifications`: rows are retained for 30 days after expiry (`expires_at <= statement_timestamp() - interval '30 days'`), regardless of used status. Unexpired and recently expired (<30 days) rows are strictly preserved.
2. `cron.job_run_details`: completed runs (`status IN ('succeeded', 'failed')`) are purged after 30 days (`end_time <= statement_timestamp() - interval '30 days'`). In-progress, running, and recent runs are strictly preserved.
3. Batch-bounded deletion: both cleanups enforce validated batch limits (1 to 1000, default 500) and `FOR UPDATE SKIP LOCKED` with statement/lock timeouts. Concurrent executions skip locked candidate rows without blocking or double-counting.
4. Privilege isolation:
   - `public.cleanup_expired_email_verifications`: `SECURITY INVOKER`, fixed empty search path. Granted to `service_role` and `postgres`. Denied to `anon` and `authenticated`.
   - `workflow_private.purge_completed_cron_job_runs`: `SECURITY DEFINER` owned by `postgres`. Granted to `postgres` only. Denied to `service_role`, `anon`, and `authenticated`.
   - `workflow_private.run_retention_maintenance`: `SECURITY DEFINER` owned by `postgres`. Uses transaction advisory lock `72631017` to prevent concurrent overlapping executions. Granted to `postgres` only.
5. Scheduled job: scheduled via pg_cron as `ecopin-retention-maintenance` at minute 39 of every hour (`39 * * * *`), eliminating collisions with `ecopin-report-lifecycle` (minute 0) and `ecopin-dispatch-watchdog` (`*/5`).

## Verification

- Isolated Docker database (PostGIS 17-3.5):
  - 34 regression assertions passed covering recent preservation, used-but-recent preservation, exact cutoff boundaries (±1s), oldest-first bounded removal, repeated batch cleanup, parameter validation, and privilege denial.
  - Concurrency: two concurrent connections verified `FOR UPDATE SKIP LOCKED` skips locked candidate rows without blocking.
  - Benchmark workload: 10,000 synthetic verification rows scanned in 1.876 ms without index. Confirmed write amplification of an index on `expires_at` is avoided until token volume justifies it.
  - Rollback and reapplication: clean up/down/up verified with complete removal of functions and cron job without data loss.
- Full backend suite: 28 test suites, 190 tests passed.
- Live database health:
  - 8 existing verification rows preserved (none expired > 30 days).
  - Auth, profile, and settings fingerprints unchanged.
  - Zero invalid indexes.
  - Completed scheduled execution observed in `cron.job_run_details`.

## Recovery

To roll back:
```powershell
node scripts/test-retention-cleanup.mjs migrations/20261011163533_enforce_verification_token_and_cron_history_retention.sql migrations/rollback/20261011163533_enforce_verification_token_and_cron_history_retention.sql tests/sql/retention-cleanup-regression.sql
```
Applying rollback SQL drops the retention functions and unschedules the cron job without altering existing token or job data.
