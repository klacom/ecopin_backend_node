# Cleanup task read authority

The cluster-task API previously returned entire service-key task rows to every signed-in caller. Task list/detail reads also embedded precise report locations before route readiness or after completion. Migration `20261011145237_authorize_and_bound_cleanup_task_reads` and the three backend read handlers close these alternate paths.

The service-only SQL invoker function reads the current profile and assignment in its statement snapshot. Desk staff retain operational details. Currently assigned crew get operational details only for ready, active tasks; assigned inactive or unready tasks retain a limited history/progress summary. Reassignment removes crew access. Crew cluster data includes the cluster ID, rather than unrelated cluster memberships.

Citizens use only the cluster-summary path, and only for tasks containing their own report or an approved, non-rejected public report with the required property consent. Summary fields omit private planning text, assignments, locations, report IDs and version/generation data. Task images are included only when every recorded member report is owned by that caller or approved on a public site; missing memberships and mixed private-owner tasks withhold images. Consent-only private public locations do not grant image access. Report evidence remains separately authorized.

List/cluster reads default to 200 rows with a sentinel, cap explicit pages at 500 and use created_at/id descending order. Responses retain arrays and set X-Has-More; detailed reads retain a single object. Protected responses use private, no-store. A client-supplied or stale request role cannot override the database result.

Validation: 29 live rollback-only assertions passed. Candidate up/down/up passed 59 assertions in a single rollback-only transaction, including restoration of function absence. All 134 backend tests passed, including 11 new read regressions and 11 existing task-photo checks. The prior 111 live privacy/projection/detail/Storage/identity checks were rerun and passed. Real HTTP confirmed anonymous EXECUTE denied, bounded service reads and unknown-actor denial.

Executed source matches the single live migration statement exactly; MD5 701f181118eedde7bc50a10d0d294992. Revert the matching backend handler change before dropping this function in an incident rollback; otherwise task reads fail closed. The rollback-only drill is not a fresh platform restore. Disk space recovered but Docker engine recovery remains pending. Real-user device sign-in, media bytes, Realtime delivery and representative workload latency remain unverified.

Function privilege design follows [Supabase database function guidance](https://supabase.com/docs/guides/database/functions). The broader 55-task optimization is still active.
