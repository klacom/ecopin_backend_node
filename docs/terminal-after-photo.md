# After photos on resolved reports

An active, assigned crew task can contain a report already marked `resolved`.
The old `set_report_photo` RPC rejected every write on that report, trapping
queued After evidence behind HTTP 409 `Report is terminal`.

Migration `20261023094056_allow_assigned_resolved_after_photo.sql` permits a
nonempty After upload on a resolved report under the existing task/report locks,
assignment checks and expected version. It preserves the report's status.
Before changes, After deletion, closed/completed/rejected reports, completed or
cancelled tasks, unauthorized crews and stale versions remain blocked.
No existing report, task or photo data is reset by the migration.

The app sends legacy terminal report statuses and task completion after the
photo pass. Failed or paused photo work blocks that pass. A successful photo
advances a queued report completion's base version only if it matched the
version accepted by that upload; unrelated/stale operations keep their version.

Run `node scripts/test-terminal-after-photo.mjs` against the local test Postgres
container (`TEST_POSTGRES_CONTAINER` defaults to `ecopin-slice-a-postgis`). The
test uses an isolated database and the actual migration function. App checks:
`flutter test --no-pub test/sync`.

Apply this migration to enable currently queued After uploads; no API restart
is needed. Deploy the app changes to prevent future completion ordering races.
Rollback can restore the prior `set_report_photo` function definition, without
deleting uploaded evidence; it restores the terminal-report upload restriction.
