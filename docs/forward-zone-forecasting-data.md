# Forward forecast data

Apply `migrations/20261018120000_forward_zone_forecasting.sql` before deploying the new forecast services. It retains existing reports and predictions, adds forward prediction fields, and installs the stable zone catalog. Run the whole migration as the database owner; PostGIS must already be installed in `extensions` (the existing project setup). A 5-second lock timeout prevents waiting indefinitely behind active work; retry during a quieter period if it fires.

The catalog is **122 genuine H3 resolution-8 cells**, generated with Python H3 4.5.0 using `polygon_to_cells_experimental(..., 8, 'overlap')` for the rectangle `[121.052, 14.530, 121.115, 14.625]` in longitude/latitude order. The exact geometry is checked into `data/pasig-h3-r8.geojson` and the migration. This is a documented Pasig study extent that also covers adjacent areas. It is not an official city or barangay boundary. Zone ids and polygons never depend on the selected forecast horizon. Do not rename these cells as administrative barangays.

`zone_weekly_report_history` is a **live view**, so no refresh schedule is needed. It uses UTC Monday buckets and counts approved reports that are neither rejected nor flagged for severe content. Resolved and closed reports remain in history: forecasts estimate incident arrivals, not the unresolved backlog. Future timestamps are excluded. Each location is assigned to the lexically first covering zone, so shared hex edges count exactly once. Missing zone/week rows represent zero reports. An indexed, stored PostGIS geometry supports assignment without reparsing polygons on every query. The ML service fills missing buckets and excludes the unfinished current week.

The zone catalog, aggregate view, and forecast cache are available only to `service_role`; keep that key on the server. Staff access goes through the role-protected backend API. The aggregate uses `security_invoker` as additional protection. No policy exposes report locations or history directly to citizen clients.

## Optional synthetic history

Use a demo or staging database for synthetic history. The script runs entirely offline and never connects to Supabase. Its default is a preview:

```powershell
node scripts/seed_historical_timeseries.mjs --dry-run --weeks 52 --as-of 2026-10-18
node scripts/seed_historical_timeseries.mjs --weeks 52 --as-of 2026-10-18 --output .private/forecast-history.sql
```

Review the generated SQL and apply it manually to the intended demo/staging database. `--output` refuses to overwrite an existing file. Add `--user-id EXISTING_PROFILE_UUID` to associate fixtures with an existing demo profile; otherwise the nullable report user is left empty. No user or credentials are created. The date must not be in the future. Rerunning identical seed/date data is idempotent; changing the seed creates another synthetic dataset, so use one seed per demo database.

The generator creates 26–52 weeks of daily waste incidents with July–October seasonality, Monday accumulation, higher rates near Pasig Mega Market, moderate Pinagbuhatan rates, and a low residential background. All fixture titles and descriptions explicitly identify synthetic data. They are approved and closed for model demonstration, avoiding dispatch queue work. They do not claim verified photographs, field cleanup evidence, or measured SLA performance. Existing rows are never deleted, and no triggers are disabled.

## Verification and rollback

```powershell
node --test --test-isolation=none scripts/test-historical-timeseries.mjs
node scripts/test-forward-zone-migration.mjs
```

The database test requires a running Docker engine and the `postgis/postgis:17-3.5` image. It creates a uniquely named disposable container, uses no project `.env` or live database connection, and removes only its own container. It checks geometry, UTC boundaries, report eligibility, shared edges, service-only grants, repeat seed safety, prediction constraints, and rollback/reapply.

The matching rollback removes new forecast columns and zones while retaining all report and prediction rows. Export forward forecast fields first if needed. It intentionally retains service-only access to the forecast cache. Old cache consumers ignore the new canonical `7d`/`30d`/`90d` rows. Do not apply the older destructive `update_hotspot_forecasting_to_report_based.sql` as a deployment step for this change.

Implementation verification: all four offline seed/catalog checks pass, and both migrations parse with PostgreSQL's parser (`pglast` 8.6). The disposable PostGIS runtime test could not run in the implementation environment because Docker Desktop crashed during startup while initializing its Inference manager. Run that test with a working Docker engine before deployment; parsing alone does not verify PostGIS execution or database privileges.
