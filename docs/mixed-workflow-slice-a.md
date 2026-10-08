# Mixed Workflow — Slice A implementation record

## Authority and scope

The [Phase 0 policy record](../mixed_workflow_phase0_results_2026-10-08.md) sets a deployment baseline for existing unresolved reports and severity tiers Low 0–33, Medium 34–66, High 67–100. The authorized temporary High maturation value is **12 hours**; normal maturation is 24 hours and breach threshold is the configured 48 hours. Historical created times and former deadlines are archived. Active task claims survive grandfathering.

Slice A covers four increments: atomic plan/group commit; standard and Sweeper fleet selection; classified failure release and site blocks; mobile authority, analytics and staging gates. Mixed satellite bundling remains Slice B. Physical volume/weight, generation receipts, contested offline completion and hazard ML remain Slice C. Slice A makes no 30-minute Mixed detour guarantee.

Before updating this file, the Supabase MCP confirmed exact live columns. `reports.location` is geography, `clusters.center` is geometry, `reports.deadline_at` and `reports.fc_version` exist, `sweeper_configuration` uses `parameter_name`/`parameter_value`, and admin settings use `optimization_settings.key`/`value`. The live enums, constraints, RLS, outlier triggers and writable `reports_view` were inspected.

## Implemented contract

- PostgreSQL derives report lifecycle and writes `sla_started_at`, `matured_at`, `breached_at`. Activation uses one database timestamp to reset unresolved reports and archive prior deadlines once. `is_outlier` remains an ordinary derived compatibility column.
- Standard plans select available, unblocked clusters. Sweeper plans select unclustered, unclaimed, unresolved maturing/breached reports; breached reports take priority. Every candidate gets a selected task or explicit `no_capable_crew`/`insufficient_capacity` reason. The current live fleet has no sweeper-capable crew; an administrator must configure one.
- Crew flags, membership, speed/service factors, current tasks, break time and shift budget are checked when planning, committing and publishing. Published routes include the return to depot and reflect the requested travel mode. Physical payload remains Slice C.
- The commit RPC locks crews and anchors in stable order, claims reports atomically per mandatory group and stores immutable group results. Publication is a second atomic transaction guarded by a 90-second lease, three attempts and a 20-second provider budget. A 30-minute watchdog releases an unpublished and unassigned claim; an actively assigned task is escalated.
- The existing officer custom-task endpoint keeps its selected-report, title and crew-member contract. A separate transaction locks all selected reports and creates one manual task only if every report is still available and unblocked. Manual tasks are directly ready for their named crew members and do not imply an optimized route.
- Transient failure releases claims and reprioritizes the intact cluster. Site/safety or unclassified failure blocks and defers it until reviewed clearance. Active/blocked clusters cannot silently gain or lose member reports.
- Field writes use server authority, operation ID replay, row-locked `fc_version` comparison and allowlisted fields. Notes are additive. Completion distinguishes cleaned from merely closed, while failed tasks release claims. Generation receipts and contested physical completion remain Slice C.
- Direct client mutations of dispatch state are revoked. RLS limits task/route reads to assigned crews and settings to desk roles. The service-backed route endpoints enforce the same crew scope. The legacy `reports_view` uses caller RLS and is read only for clients.
- Analytics use historical `breached_at`, real task durations and task taxonomy. Clustering excludes active claims, existing members and blocks. Existing outlier consistency triggers were repaired for the fixed-path RPCs.

## Consolidated acceptance matrix

| Invariant | Slice A evidence | Future scope |
| --- | --- | --- |
| I1 terminal lifecycle matches terminal report status | Lifecycle SQL regression | — |
| I2 dispatched matches active claim | Commit/release SQL tests | — |
| I3 fresh/maturing/breached membership | Lifecycle and cluster guard tests | — |
| I4 maturation/breach stamps write once | Lifecycle SQL tests | — |
| I5 at most one active task per report | Two-connection claim test | — |
| I6 satellites subset of anchor | No satellites in A | Slice B |
| I7 unique plan group and target | Constraints and save validation | — |
| I8 satellite count and detour cap | No bundling in A | Slice B route-matrix pilot |
| I9 time/task and physical load | Commit/publish time and task checks | Payload/certification in C |
| I10 blocks excluded until clearance | Access block and failure tests | — |
| I11 immutable operation IDs and physical reconciliation | CAS/replay/conflict audit tests | Generation receipts/contested work in C |

Local gates: **62 Jest tests in 11 suites**, **31 lifecycle SQL assertions** and competing-worker test, dispatch SQL with live trigger shapes, two-connection plan/manual claim and mobile-write races, actual authenticated/service-role checks, modified web lint, web production build, Dart analysis of modified mobile files and browser component inspection. Backend, web and mobile host releases and operational Sweeper staffing require separate verification.

## File index

- Migrations: [lifecycle](../migrations/20261008064832_report_lifecycle_foundation.sql), [claims](../migrations/20261008071533_slice_a_dispatch_claims.sql), [fleet/failures](../migrations/20261008072440_slice_a_fleet_and_failures.sql), [routes](../migrations/20261008073726_slice_a_route_publication.sql), [mobile authority](../migrations/20261008075500_slice_a_mobile_authority.sql), [scheduler](../migrations/20261008082000_slice_a_scheduler_activation.sql), [photo authority](../migrations/20261008083500_slice_a_report_photo_authority.sql), [mobile view version](../migrations/20261008085000_slice_a_mobile_view_version.sql), [manual task compatibility](../migrations/20261008101500_slice_a_manual_task_compatibility.sql).
- Planning: `src/modules/optimization/services/{planningPolicy,dispatchPlanner,dispatchCommit,routeGenerator,workQueue,mcdaPrioritizer,fleetPolicy,taskFeedback}.js`; `src/modules/optimization/providers/distance.provider.js`; optimization controller/routes.
- Execution: `src/controllers/{cleanup_task,fc_sync,sync,field-report-photo}.controller.js`, `src/middleware/field-report-write.middleware.js`, cleanup/report routes.
- Lifecycle: `src/jobs/{cron,dispatch-watchdog}.js`, `src/index.js`; clustering controller/service; sweeper analytics, SLA and configuration controller/service/routes.
- Web: optimization officer/admin pages, `components/optimization/{FleetCapabilities,OptimizationSettings}.js`, `components/context/TaskContext.js`, `components/ui/TemplateSelector.js`.
- Mobile: `lib/shared/reports/data/models/report_model.dart`, field-crew report repository, cleanup-task model/repository, outbox sync manager and photo sync manager. These send numeric `base_version`, retain server-returned versions and keep report photo operations in the dedicated uploader.
- Tests: `scripts/test-{report-lifecycle,dispatch}.mjs`, `tests/sql/{report-lifecycle,dispatch-bootstrap,dispatch-regression}.sql` and associated Jest suites.

## Deployment and recovery

All **nine** SQL migrations were applied through Supabase migration tracking on 2026-10-08. The local CLI migration directory does not reproduce the existing project schema, so do not use `supabase db push`. Lifecycle activation ran at `2026-10-08 09:43:03.801945 UTC` with `activate_report_lifecycle(12,24)`: 49 unresolved reports received the same reset start and 48-hour deadline, 49 prior deadlines were archived, zero immediately breached, and both existing active claims were retained. State counts were fresh 29, clustered 18, dispatched 2. A retry returned zero resets and `alreadyActivated=true`. Manual lifecycle advance and watchdog found no due work.

Two durable `pg_cron` jobs are installed: hourly lifecycle advance and a five-minute unpublished-claim watchdog. The first scheduled lifecycle run and watchdog tick both succeeded at `10:00 UTC`; the lifecycle audit row was written at `10:00:00.066935 UTC`. Watchdog ticks also succeeded at `09:45`, `09:50` and `09:55 UTC`. The unresolved report state counts remained 29 fresh, 18 clustered and 2 dispatched. Node scheduling requires a deployed backend revision with `REPORT_LIFECYCLE_ENABLED=true`; the new backend, web and mobile code has not yet been released to its hosts.

Preserve the marker and reset archive. During an interrupted rollout, disable scheduling while investigating. Do not restore old deadlines over reports created or updated since activation. An unpublished claim can be regenerated after expiry; site blocks require officer clearance.
