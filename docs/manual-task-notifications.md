# Atomic manual-assignment notifications

The backend previously committed a manual task and then attempted a notification
insert using nonexistent `notifications.cleanup_task_id` and unsupported enum
value `task_assigned`. Its error was logged after the task had already succeeded.

`create_manual_cleanup_task` now inserts one supported `general` notification per
explicit assignee inside the same transaction as the task, report claim and
canonical receipts. Single-report assignments retain their report reference.
Unassigned tasks produce no notification. The backend no longer performs a
separate insert. The existing function owner, EXECUTE permissions, validation and
fixed search path are unchanged; only the trusted backend can call it.

Verification: the backend regression failed before repair and passes afterward;
all 193 backend tests in 29 suites pass. Six rollback-only database checks prove
creation, empty assignees, canonical receipts, duplicate-claim conflict and complete rollback on
an injected notification failure. Two physical connections prove the second
claim conflicts while the first holds its row, leaving one committed task and
one notification. Local rollback reproduces the old missing-notification behavior;
reapplication passes. No test trigger or fixture was deployed to the hosted project.

Live migration: `20261012041041_make_manual_task_assignment_notifications_atomic`.
Executed statement/source MD5: `7a9fe19d165aa8ebe9488cd691c55497` after normalizing
file line endings and removing its final newline. Existing reports, tasks,
notifications, Auth records and function owner/ACL fingerprints are unchanged.

Run `node scripts/test-manual-task-notifications.mjs` and
`node scripts/test-manual-task-concurrency.mjs` against the owned local recovery
stack. Both refuse unrelated Docker project labels; SQL fixtures roll back or
are removed by their freshly generated IDs. The captured rollback restores the
old missing-notification behavior for isolated recovery testing; restoring it
on live would require a forward fix for notification delivery.

This closes the manual-task notification defect. Full dispatch, cancellation,
group retry and external event delivery remain separate W06 acceptance work.
