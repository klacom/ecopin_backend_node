# PDT-25: dashboard lifecycle reconciliation

## Audit, 29 October 2026

The current database contains **577 stored reports**. The old Admin breakdown displayed 475 Unresolved + 15 Resolved + 0 Pending = 490, leaving **87** unexplained. Those omitted raw states are 33 `closed`, 16 `pending_owner_consent`, 4 `in_progress` and 34 `rejected`. The task's historical figure of 86 cannot be reconstructed without its original snapshot; the current discrepancy is 87. No records were missing from the total, and no report rows were rewritten for this fix.

The new snapshot reconciles as follows:

| Current lifecycle | Reports |
| --- | ---: |
| Submitted | 13 |
| Verified | 371 |
| Assigned | 104 |
| In progress | 4 |
| Resolved | 48 |
| Rejected | 37 |
| Uncategorized | 0 |
| **Total** | **577** |

Resolved includes 15 `resolved` and 33 `closed`. Rejected includes 34 raw `rejected` statuses and 3 other reports with rejected validation. Verification and task assignment explain why the lifecycle counts differ from the original status counts. Figures are a dated audit, not permanent dashboard constants.

## Classification contract: pdt25-v1

Every stored row belongs to exactly one bucket, in this order:

1. Missing or unsupported response status: Uncategorized, regardless of other metadata. Include the original status/count in diagnostics.
2. `resolved`, `closed`, `completed`, `waiting_for_feedback`: Resolved.
3. Rejected status or validation decision: Rejected.
4. In-progress status or stage: In progress.
5. Linked cleanup task, assigned status or assigned stage: Assigned.
6. Approved/validated validation, verified status or acknowledged stage: Verified.
7. Remaining recognized states: Submitted.

Recognized intake states include `unresolved`, `pending`, `submitted` and `pending_owner_consent`. Stage `responded` alone is deliberately not resolution evidence: the existing before-photo workflow writes that stage before cleanup is complete. Terminal response status takes precedence over leftover stage/task/validation fields. This is a presentation classification, not a change to report workflow or trust rules.

These are mutually exclusive **current states**, not cumulative counts of reports that ever passed a milestone. Totals include closed/rejected/private reports that remain stored, without public map/consent filters or a date filter. Deleted/withdrawn rows are not reconstructed. Operational queue/SLA cards have a narrower scope and are not an alternative lifecycle partition.

## Snapshot and access

`public.get_report_lifecycle_summary()` reads the report table once in one SQL statement, materializes the classification and produces total, all seven buckets, original statuses, unknown-status diagnostics, statement time and version from one MVCC snapshot. There is no paged REST-row cap or separate total query that can race concurrent updates. `byStatus` remains available for existing API consumers.

Only `service_role` can execute the SECURITY INVOKER function; PUBLIC, anon and authenticated have no execute grant. The existing authenticated Officer/Admin `GET /api/admin/stats` route remains the boundary. The aggregate contains no report IDs or reporter identity. Existing RLS policies and report contents are unchanged.

The backend validates aggregate shape and reconciles all sums before responding. A missing function, database error, malformed/partial snapshot or incompatible version fails the request instead of returning plausible zero counts. Both dashboards validate the snapshot, offer Retry, and label retained data on refresh failure. The account-scoped dashboard cache invalidates after data-changing actions.

## Verification and rollout

- Backend Jest: 363 tests across 39 suites passed, including endpoint error handling and one-RPC snapshot enforcement.
- PostgreSQL/PGlite regression: 3 tests passed, covering empty data, legacy/unknown/conflicting states, more than 1,000 rows, and execution grants. Run `node --test tests/report-lifecycle-summary-db.test.mjs` with the existing optional `@electric-sql/pglite` test tool installed.
- Web unit/deadline suites: 150 tests passed. Scoped ESLint and Next production build passed.
- Chromium fixtures: Admin/Officer at 1440px light (720px high) and 320px dark. Cover all seven rows, sum equality, a synthetic 86-report Uncategorized bucket, empty totals, 503/retry, reachable definitions/activity, no horizontal overflow or runtime errors. Fixtures exercise local production code, not a deployed staff API.
- Direct hosted SQL and a service-role PostgREST RPC returned matching totals of 577. Anonymous/authenticated execution is denied.

Database migration is **already applied** to EcoPin (`wcruoyygungqxazdwhtv`): hosted ledger `20261029101044_report_lifecycle_summary`. Its checked-in equivalent is `migrations/20261029123000_report_lifecycle_summary.sql`; the Supabase tool generated the hosted timestamp. Do not apply it a second time to that project. For another database, apply the local migration before releasing the API.

**Backend and web application changes still need deployment.** Release the backend against the migrated database, then the web dashboard. Verify the authorized stats endpoint and both hosted dashboards against the same current snapshot after release. Counts may legitimately change as reports are created or updated.
