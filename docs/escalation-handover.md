# Production ownership of the five-day escalation job (T11 procedure, executed in T15)

Today the job runs only in the original backend on the operator's machine (port 4002 in the investigated setup), which shares the production database. The recovery candidate must take over without a gap and without duplicate notices. This document is a procedure; nothing in it was run against production during preparation.

## What makes an overlap safe

`public.escalate_unprocessed_reports()` is the only writer. It locks eligible reports with `FOR UPDATE SKIP LOCKED`, re-reads eligibility after locking, claims each report/recipient/age-day in `workflow_private.unprocessed_alert_deliveries` (primary key, `ON CONFLICT DO NOTHING`) and inserts the notices in the same transaction. A failed run leaves no claim. Two enabled processes (the local owner and production) therefore cannot notify the same recipient twice for the same report and age day, even if they fire at the same minute. The local database tests prove this (`scripts/test-escalation-isolated.mjs`: eligible/ineligible, suspended staff, repeat run, injected failure then retry, two concurrent committed sessions, next-day reminder, public roles denied). In-process overlap is also prevented and counted (`tests/unprocessed-escalation-job.test.js`).

Overlapping owners for a short period is the intended handover; a gap is the risk to avoid. Do not stop the local owner before step 4.

## Preconditions (all must be true before step 1)

1. T15 has deployed the candidate release through the existing mechanism, and the running process, symlink and gateway agree on the selected SHA.
2. The production host sets `NODE_ENV=production` **and** `DEPLOYMENT_ENV=production` (T02 guard; without it the candidate refuses to start against the production project). Set it in the protected environment file only; do not copy values into documents.
3. The hosted database already has the escalation function and the baseline row (recorded read-only in T03). Re-check read-only before enabling: `workflow_private.unprocessed_escalation_baseline` has one row, and `escalate_unprocessed_reports()` includes the baseline condition. If the baseline row is missing, **stop**: enabling would notify for the entire existing backlog.
4. Count what the first run may create, read-only, and write the number down: eligible reports are those in `workflow_private.unprocessed_report_alerts` with `age_days >= 5` and `created_at` after the baseline cutoff; expected first-run notices are eligible reports times active officer/admin profiles, minus existing ledger rows. A first run far above this number is a stop condition.
5. A rollback target for the web/backend release exists (T01b) and the person executing it is identified.

## Procedure

1. **Register in production.** Through the protected configuration mechanism set `UNPROCESSED_ESCALATION_ENABLED=true` (leave `UNPROCESSED_ESCALATION_CRON` unset for the default `*/15 * * * *`, Asia/Manila). Restart through the existing mechanism, off-peak, accepting the short restart outage.
2. **Confirm registration.** Within a minute the log shows `[UnprocessedEscalation] registered` and `GET /health` shows `jobs.unprocessed_escalation.enabled: true` with a `registered_at` timestamp and `last_run_at: null`. Evaluate the JSON body, not the HTTP status: `/health` returns 503 when the classifier or ffmpeg is degraded, independent of this job.
3. **Prove a production run.** Wait up to two schedule periods (30 minutes). Required: `last_outcome: "ok"`, `consecutive_failures: 0`, `last_run_at` within the last 20 minutes, a plausible `last_duration_ms`, and `last_notifications_created` no larger than the number from precondition 4. Then verify in the database, read-only, that the ledger has no duplicate (report, recipient, age day) and that notices created since step 1 match the ledger. Keep both owners enabled for at least one further period and confirm both report `ok`.
4. **Retire the local owner, only after step 3 passed.** Set `UNPROCESSED_ESCALATION_ENABLED=false` in the local backend's configuration and restart it, or stop that process; the operator performs this, not an automated step. Record the time.
5. **Verify after retirement.** Two further production runs succeed (`last_run_at` advances, `consecutive_failures` stays 0). Watch for 24 hours; the missed-run limit below applies.

## Acceptance limits for monitoring

- Missed run: `last_run_at` older than 30 minutes (two periods) while `enabled` is true.
- Failing: `consecutive_failures >= 2`, or `last_outcome: "failed"` on two consecutive observations.
- Stuck: `skipped_overlaps` rising each period, or `last_duration_ms` above 15 000 (the run aborts at 20 000).
- Backlog: `last_reports_checked` equal to 500 means more work remains and is processed in later runs; sustained 500 needs review.
- Status is held in process memory. After any restart `last_run_at` is null until the next scheduled run (at most 15 minutes); that is not a failure.

## Rollback

- Production job misbehaves (stop conditions above, unexpected burst, duplicates): set `UNPROCESSED_ESCALATION_ENABLED=false` and restart production; delivery stops immediately. If the local owner was already retired, re-enable it the same way so coverage is not lost. Do **not** delete ledger rows or notices; the ledger prevents re-sending what was already delivered. Decide separately, with the product owner, about removing unwanted notices.
- Release failure: use the documented application rollback target and re-verify the running release. Code rollback does not reverse data; no schema change is part of this handover.
- Never run `escalate_unprocessed_reports()` by hand in production, and never point the isolated scripts at production (they check the local container and project label before acting).

## Evidence to record in T15

Selected SHA and process identity; the precondition 4 count; log line and `registered_at`; two consecutive successful health snapshots with counts and durations; the ledger duplicate check result; the time the local owner was retired; the post-retirement runs.
