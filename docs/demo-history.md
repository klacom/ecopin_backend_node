# Populate a working demo database

From `C:\dev\ecopin\ecopin_backend_node`:

```powershell
npm run db:populate-demo:dry
npm run db:populate-demo -- --confirm
```

The first command is a read-only preview. The second uploads 40 illustrative waste
photos from `../sample_images` into the existing private `Report Evidence` bucket,
then writes **`.private/demo-history.sql`**. Open that file, copy its entire contents
into the **Supabase SQL Editor**, select the **postgres** role, and run it once.
Preparing the file does not insert database rows. Never run just selected sections
of the generated SQL: the transaction restores the paused timestamp triggers.

For one month instead of two:

```powershell
npm run db:populate-demo -- --confirm --days 30
```

The script reads the backend `.env` using the project's existing
`NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SERVICE_ROLE_KEY` names. It also accepts
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`. Credentials never appear in the SQL.
The generated file contains existing account IDs and stays in the ignored
`.private` directory. Check the target project printed by the preview.

## What it creates

The default 60-day history contains 552 waste reports at simulated Pasig locations,
120 clusters, 114 cleanup tasks and matching plans, planning jobs, optimization
runs and crew routes, plus waypoints, assignment receipts, report outcomes,
resolution events, load readings, access failures, review items, notifications,
response logs, offline completion logs and synthetic daily hotspot predictions.
Most older reports are resolved or citizen-closed. Recent assignments and a small
backlog remain open, and four new reports await manual review.

Reports use varied titles, dates, severity, priority and satisfaction ratings.
Media uses the application's private `storage://` references. Photos are reused
and explicitly illustrative; no fabricated after-photo is substituted for cleanup
evidence. Prediction scores are simulated, not output from the ML service. No
artificial sync conflicts are inserted merely to make error tables nonempty.

Existing citizens, an officer/admin and at least one staffed field crew are
required. Suspended users and disabled crews are excluded. Accounts, crew
membership, configuration, strikes, authentication and system logs are preserved.
The script adds operational records; it does not clear existing ones.

## Historical timestamps and reruns

The regular API resets report SLA clocks to the current time. The SQL import uses
the configured maturation/SLA durations, temporarily pauses only report lifecycle,
deadline and generic timestamp triggers, and restores their original enabled
states before committing. Claim guards, receipt generation, other security
triggers and foreign keys stay active. The affected tables are locked during the
short import, so run it while the demo is idle. Any SQL error rolls back the rows
and trigger changes together. If the editor leaves a failed transaction open,
run `ROLLBACK;` before retrying the whole file.

Stable IDs and an import marker prevent duplicate history. To replace a previous
seed, use **`scripts/clear-reports-and-clusters.sql`** first: the REST cleanup script
cannot remove immutable dispatch commits. Cleanup removes operational records,
including unrelated existing activity, so use it only when you intend a reset.
Re-run preparation to refresh the history dates. Uploads use only the dedicated
`ecopin-demo-history-v1/` folder and can be reused after a failed preparation/import;
they are not rolled back with SQL and do not change bucket access policies.

## Verification

The import checks report/outcome counts before committing and returns report
counts by status. Afterward, open the officer report map, operations, routes,
review inbox, response logs and analytics screens. Current reports remain subject
to the normal background lifecycle and dispatch workers.

Focused generator checks:

```powershell
npm test -- --runInBand tests/demo-history.test.js
```
