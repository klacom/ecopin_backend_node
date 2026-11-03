# Production parity prerequisite matrix

Audited 3 November 2026. Hosted checks were catalog-only/read-only against project `wcruoyygungqxazdwhtv`. No production migration is indicated by this audit. Migration names and actual definitions were matched; timestamp equality was not required.

All 18 directly required RPC bodies match the latest reviewed migration definitions after ignoring full comment lines and CRLF/LF representation. Twelve bodies also match without that normalization. Arguments, results, owners, security settings and effective grants are preserved in the isolated restoration. Every selected RPC permits `service_role` execution and denies direct `anon`/`authenticated` execution; the backend must bind the actor to the authenticated session and enforce the feature role.

| Capability | RPC / runtime prerequisite | Principal relations and helpers | Reviewed migration / hosted result |
| --- | --- | --- | --- |
| T04 executive report | `get_barangay_executive_analytics`, `get_barangay_operational_analytics` | profiles, reports, official 30-row barangay roster, analytics helpers | `20261029170000_barangay_executive_snapshot`; analytics updated by `20261030070000_barangay_unassigned_reasons`. Both present and compatible. Executive migration already applied: do not replay. |
| T05 event history | `read_operational_events` | operational_events, operational_private journal helpers/triggers, task/report references | `20261029150000_operational_event_journal`; present and compatible. |
| T05 live feed/presence | `read_live_operations`, `touch_crew_presence` | operational_events, cleanup_tasks, profiles, operational_private.crew_presence | `20261030040000_live_operations_feed`; present and compatible. Presence is a write; it was not invoked on production. |
| T06 citizen/staff support | `create_support_ticket`, `read_my_support_tickets`, `read_my_support_ticket`, `read_support_ticket_queue`, `respond_support_ticket` | support_tickets, support_ticket_number_seq, support_ticket_json, profiles, report ownership | `20261030050000_support_tickets`; present and compatible. Citizen/staff role and ownership checks remain required. |
| T07 directions | Registered authenticated route, bounded coordinates, reachable configured OSRM provider | No feature database migration or RPC | Existing routing controller handles provider calls. Runtime/provider verification remains T07; this catalog audit does not establish provider availability. |
| T08 case export | `read_incident_case_record` | reports, cleanup_tasks, journal/activity/history relations and protected views | `20261029160000_incident_case_record`, latest `20261030120000_fix_case_record_coordinates`; hosted body matches the coordinate fix even though that exact filename/timestamp is not in the ledger. No blind replay. |
| T09 proof review/publication | `read_cleanup_proof_source`, `publish_cleanup_proof_photos`, `read_cleanup_proof`, `read_report_identity_context` | cleanup_proof_publications, reports, workflow_private proof helpers, privacy_private owner context, Cleanup Originals / Cleanup Proof buckets | Review migration plus `20261102120000_cleanup_proof_multiple_photos`; present and compatible. Ledger records the multiple-photo migration under `20261101190111`. |
| T10 crew summary | `get_field_crew_operations_summary` | operational_events, cleanup_tasks, profiles, crew assignment/route/waypoint relations | `20261030010000_field_crew_operations_summary`; present and compatible. |
| T11 escalation | `escalate_unprocessed_reports`, `read_unprocessed_report_alerts`; separately registered Node scheduler | workflow_private.unprocessed_report_alerts, unprocessed_alert_deliveries and baseline; reports, cleanup_tasks, profiles, notifications | Escalation migration plus `20261030080000_unprocessed_escalation_baseline`; present and compatible. Hosted baseline row exists. Dedicated Node scheduler ownership remains T11/T15; existing DB cron jobs are different jobs. |

## Grants, policies and storage

The audited public application tables have RLS enabled. Private application schemas, two non-login/non-bypass reader roles, view ownership/security options, trigger definitions and grants are retained. The local copy matches 57 tables/columns, 141 function definitions, seven views, 24 enums, six sequences, 139 indexes, 41 application-table triggers, 93 policies and 1,600 effective grant entries from the scoped snapshot. The application-owned Auth user-creation trigger is restored separately; its function creates only a citizen profile. Six application schemas were restored. Two CHECK constraints have equivalent PostgreSQL patch-version deparsing of varchar-array-to-text casts; accepted, rejected and NULL inputs were checked for identical results. Their tests were not weakened to claim byte equality.

| Bucket | Public? | Limit / MIME | Access prerequisite |
| --- | --- | --- | --- |
| Cleanup Originals | No | 10 MiB; JPEG, PNG, WebP | No direct anon/authenticated read policy. Backend service access plus owner/staff authorization is required. |
| Cleanup Proof | No | 10 MiB; JPEG | Published bytes must be delivered through the publication-aware backend handler, not a public bucket URL. |
| Report Evidence | No | 10 MiB; JPG/JPEG, PNG | Existing authenticated upload and read policies; feature-specific access still needs verification. |
| Report Cleanup | No | 10 MiB; JPG/JPEG, PNG, WebP | Existing upload authority helper; legacy authenticated SELECT policy is broad. |
| Cleanup Task Photos | No | 10 MiB; JPG/JPEG, PNG, WebP | Existing upload authority helper; legacy authenticated SELECT policy is broad. |

Important T09 follow-up: private bucket flags alone do not establish per-owner privacy. Legacy Report Evidence/Report Cleanup/Cleanup Task Photos SELECT policies allow authenticated reads by bucket. This is recorded for the actual legacy-byte/access audit; it must not be described as owner isolation or copied into a new protection design. The two dedicated proof buckets deny direct anonymous and citizen byte access in the isolated tests. No hosted storage objects or report records were downloaded.

## Isolated baseline and verification

`supabase/baseline/application.sql` is a **local bootstrap snapshot**, not a production migration. It was rendered from schema metadata only and verified against the hosted scoped catalog. It assumes the local Supabase platform's Auth/Storage schemas already exist, uses the local platform restore role to preserve ownership, and refuses a nonempty public application catalog. It does not include production rows, secret values, uploaded objects, cron job registrations or sequence current values. Do not copy it into the production migration directory or run it against a hosted database.

From this candidate checkout, with T02's isolated stack and five Auth fixtures already initialized:

```powershell
node scripts/restore-local-baseline.mjs
node scripts/verify-local-prerequisites.mjs
```

The restore script fixes its target to the owned local Docker project/workdir and verified Windows engine. On the current already restored stack, use `node scripts/restore-local-baseline.mjs --seed-only` only when refreshing the known synthetic actor/reference fixtures. It never resets existing application tables. A second full restore correctly refuses to overwrite them.

The local seed maps only the five marked synthetic Auth users into authoritative profiles, inserts the same 30-name roster already committed in the repository, creates the five private application bucket definitions, and establishes a synthetic local escalation cutoff. It does not invent geographic boundary polygons. Boundary-provider/data acceptance remains part of the relevant analytics/routing workflows; missing local polygons must continue to fail closed rather than be represented as real barangay boundaries.

The verifier passed 20 actual local checks: staff executive/history/live feed/crew-summary and citizen/staff support prerequisites, denied citizen staff access, absent-case/proof behavior, identity context, all 18 RPC privilege restrictions, and actual JPEG byte round trips with anonymous/citizen denial for both dedicated private proof buckets. Synthetic image objects are cleaned up. These are prerequisite checks, not completed T04-T11 end-to-end acceptance. No escalation job or production-write RPC was invoked on the hosted project.

## Recovery and rollout boundary

No new hosted prerequisite migration was found necessary, so there is no production migration to apply or reverse in T03. The initial local restore's permission failure rolled back completely before restoration under the local platform restore role. The successful baseline matched the scoped metadata, and refusal on an already populated catalog is checked to avoid overwriting local fixtures. Data-volume retention remains the recovery path for this disposable local platform; never use a destructive reset on the production project.

Because this work changed no hosted schema, it introduces no new database incompatibility for the preserved `5fc531d` operating fallback. That fallback retains its known missing-feature limits and is not a fully verified parity release. T15 must reassess any later schema/data changes and preserve storage/privacy and scheduler ownership before selecting a rollback. T04-T11 must still establish real authorized workflows; T14 must resolve the inherited test-suite blockers. The T02 production startup marker remains a separate pending T15 configuration change.
