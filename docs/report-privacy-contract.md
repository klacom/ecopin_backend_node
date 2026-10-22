# Report privacy contract

Applied to live EcoPin as migration `20261011143242_enforce_private_report_access_contract` on 11 October 2026, after the user confirmed all apps run locally. The local public backend feed passed HTTP checks both before and after deployment.

Anonymous maps use the explicit 19-field `public_reports` projection. Anonymous access to `reports` and `reports_view` is retired. Authenticated full report reads require ownership, a current officer/admin profile, or a current field-crew profile with a ready, active task assigned to that user. User-editable or stale JWT roles cannot grant access. Service access is preserved.

Live verification: 28 privacy, 13 projection, 12 detail, 44 cleanup Storage and 14 request identity assertions passed (111 total). Fixtures are rolled back. Counts stayed at 49 reports, 7 tasks, 8 clusters, 9 profiles and 59 notifications. All six settings hashes stayed unchanged; 166 indexes remain valid and both scheduled jobs remain active.

Run `node scripts/test-report-privacy.mjs` for a fresh isolated synthetic PostGIS up/down/up verification. It checks exact restoration of report policies and effective table/column privileges. The supplemental ACL fixture reconstructs the captured pre-contract live grants because the earlier catalog baseline omitted several table privileges and insert-column grants. It is a test fixture, never a production migration.

After disk and Docker recovery on 11 October 2026, the saved source passed 111 checks in a new isolated container, exact policy/ACL restoration on rollback, and 28 privacy checks after reapplication. The migration source matches the live ledger exactly (MD5 416124e93a824f94ce8b34a6a3009e10). Limited Auth and Storage shims make this a schema regression drill rather than a complete platform restore.

The rollback deliberately restores the previous broad report policies and anonymous grants. Use only for emergency compatibility recovery, because it reopens the verified privacy defects. These SQL and local HTTP checks do not establish real-user mobile login, media delivery, Realtime delivery or workload performance. The broader 55-task optimization remains incomplete.
