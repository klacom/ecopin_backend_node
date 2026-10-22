# Independent crew authority repair

12 October 2026, Asia/Manila. Live migration `20261012020142_restore_person_scoped_task_authority_and_canonical_receipts`.

The other agent's crew reconciliation preserved a useful feature: trusted desk membership changes synchronize active task person assignments and issue fresh-generation receipts. It also widened authority through a separate team-membership branch. A person excluded from a nonempty explicit task assignment could read operational detail, appear in assigned-only lists, execute online actions and read the base task row. Receipt minting also accepted a stale report_ids array entry whose report was currently claimed by another task.

An independent disposable regression reproduced five failures across twelve assertions. The repair restores explicit assigned_crew_ids as person authority across execution, authenticated task RLS and the bounded task-read RPC. Receipt minting uses the canonical reports.cleanup_task_id claim. Trusted team synchronization and generation propagation are retained; twelve existing new-member happy-path checks still pass.

Verification: twelve live rollback-only assertions pass, including actual authenticated JWT/RLS reads, legitimate explicit assignee allow cases, denied teammate reads/actions and stale cross-task receipt denial. Auth/profile/report/task/receipt/token/settings fingerprints match before/after. No persisted profile role, new Auth account, fixture task or report remains. Live receipt review found zero cross-task receipts requiring historical cleanup.

Fresh recovery verifies the actual paired rollback, restoring prior function definitions, EXECUTE ACLs, owners and the task policy exactly, then restores the repaired state on reapplication. Existing canonical suites comprise 174 assertions across task reads, report privacy, public projection, detail, Storage metadata, offline identity and retention. Synthetic Auth/Storage/cron shims are not full platform recovery.

The earlier crew migration has NULL live ledger statements. Its local candidate source differs textually from captured live function definitions. The verifier therefore constructs its authority baseline from the captured live rollback definitions before checking exact rollback, instead of treating that predecessor file as proof of source equality. The live repair is fully recorded: one statement, 7,100 characters, MD5 `36927df3cb8029d8d292ec7231f400ea`.

Emergency rollback restores known unsafe team widening and stale-array receipt behavior. Prefer forward repair; do not routinely roll this back on live data. Function/source restoration is not restoration of deleted or changed application rows.

Remaining gates: active/history access semantics, completed-task direct reads, assignment removal/reassignment, concurrent desk/planning changes, real device journeys and a deliberate team/person/junction ownership model. C03 normalization was not implemented by the predecessor; it still uses arrays. This repair does not claim all 55 tasks complete.

Run from the backend root:

```powershell
node scripts/test-crew-authority-repair.mjs
node scripts/test-real-worker-fencing.mjs
```

The worker test uses two physical connections, observes the first claim holding its transaction, and verifies the second claims another job before the first releases its row. It also tests stranger/stale completion denial and watchdog recovery. The predecessor's single-transaction sequential worker calls did not establish concurrency.
