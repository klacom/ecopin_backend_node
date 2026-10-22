begin;

alter table public.field_crews
  add column if not exists vehicle_type public.vehicle_type_enum not null default 'compactor',
  add column if not exists hazmat_certified boolean not null default false,
  add column if not exists certifications text[] not null default '{}',
  add column if not exists max_volume_m3 numeric(8,3) check(max_volume_m3>0),
  add column if not exists max_weight_kg numeric(10,2) check(max_weight_kg>0),
  add column if not exists starting_volume_m3 numeric(8,3) check(starting_volume_m3>=0),
  add column if not exists starting_weight_kg numeric(10,2) check(starting_weight_kg>=0),
  add column if not exists load_measured_at timestamptz,
  add column if not exists certification_reviewed_by uuid references public.profiles(id);
alter table public.field_crews
  add constraint field_crews_volume_not_overfilled check(starting_volume_m3 is null or max_volume_m3 is null or starting_volume_m3<=max_volume_m3),
  add constraint field_crews_weight_not_overfilled check(starting_weight_kg is null or max_weight_kg is null or starting_weight_kg<=max_weight_kg),
  add constraint field_crews_load_has_measurement check((starting_volume_m3 is null and starting_weight_kg is null) or load_measured_at is not null);

alter table public.work_time_configuration
  add column if not exists estimated_volume_m3 numeric(8,3) check(estimated_volume_m3>=0),
  add column if not exists estimated_weight_kg numeric(10,2) check(estimated_weight_kg>=0),
  add column if not exists estimate_source text,
  add column if not exists estimate_reviewed_at timestamptz;

alter table public.dispatch_plans drop constraint if exists dispatch_plans_mode_check;
alter table public.dispatch_plans
  add constraint dispatch_plans_mode_check check(mode in ('standard','sweeper','mixed')),
  add column if not exists capacity_breakdown jsonb not null default '{}'::jsonb,
  add column if not exists route_proposal jsonb,
  add column if not exists rejected_bundles jsonb not null default '[]'::jsonb,
  add column if not exists solver_diagnostics jsonb not null default '{}'::jsonb,
  add column if not exists planning_as_of timestamptz,
  add column if not exists generation_job_id uuid;

alter table public.dispatch_plan_items drop constraint if exists dispatch_plan_items_item_type_check;
alter table public.dispatch_plan_items drop constraint if exists dispatch_item_target;
drop index if exists public.dispatch_unique_group;
alter table public.dispatch_plan_items
  add column if not exists anchor_cluster_id uuid references public.clusters(id),
  add column if not exists cluster_ids uuid[] not null default '{}',
  add column if not exists bundle_order smallint,
  add column if not exists detour_minutes numeric(6,2) check(detour_minutes>=0),
  add column if not exists estimated_volume_m3 numeric(8,3),
  add column if not exists estimated_weight_kg numeric(10,2),
  add column if not exists load_snapshot jsonb,
  add column if not exists commit_disposition text not null default 'pending' check(commit_disposition in ('pending','included','omitted')),
  add column if not exists commit_reason text,
  add column if not exists committed_task_id uuid references public.cleanup_tasks(id),
  add constraint dispatch_plan_items_item_type_check check(item_type in ('cluster','report','bundled_report')),
  add constraint dispatch_item_target check(
    (item_type='cluster' and cluster_id is not null and report_id is null and anchor_cluster_id is null)
    or (item_type='report' and report_id is not null and cluster_id is null and anchor_cluster_id is null)
    or (item_type='bundled_report' and report_id is not null and cluster_id is null and anchor_cluster_id is not null));
create index if not exists dispatch_item_group_idx on public.dispatch_plan_items(dispatch_plan_id,group_key);

alter table public.cleanup_tasks drop constraint if exists cleanup_tasks_dispatch_kind_check;
alter table public.cleanup_tasks
  add constraint cleanup_tasks_dispatch_kind_check check(dispatch_kind in ('standard','sweeper','mixed')),
  add column if not exists satellite_report_ids uuid[] not null default '{}',
  add column if not exists bundle_detour_min numeric(6,2) check(bundle_detour_min>=0),
  add column if not exists estimated_volume_m3 numeric(8,3),
  add column if not exists estimated_weight_kg numeric(10,2),
  add column if not exists load_estimate_confidence text,
  add column if not exists route_revision bigint not null default 0,
  add column if not exists assignment_generation bigint not null default 0;

alter table public.route_waypoints add column if not exists report_id uuid references public.reports(id);
create index if not exists route_waypoints_report_idx on public.route_waypoints(report_id) where report_id is not null;

create table if not exists public.plan_generation_jobs (
  id uuid primary key default gen_random_uuid(),
  requested_by uuid not null references public.profiles(id),
  mode text not null check(mode in ('standard','sweeper','mixed')),
  status text not null default 'queued' check(status in ('queued','running','completed','failed')),
  idempotency_key text,
  requested_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  lease_until timestamptz,
  worker_token uuid,
  settings_snapshot jsonb not null,
  plan_id uuid unique references public.dispatch_plans(id),
  error_code text,
  solver_diagnostics jsonb not null default '{}'::jsonb
);
create unique index if not exists plan_generation_idempotency on public.plan_generation_jobs(requested_by,idempotency_key)
  where idempotency_key is not null;
create index if not exists plan_generation_claim on public.plan_generation_jobs(requested_at)
  where status='queued';
create index if not exists plan_generation_expiry on public.plan_generation_jobs(lease_until)
  where status='running';
alter table public.dispatch_plans add constraint dispatch_plans_generation_job_id_fkey
  foreign key(generation_job_id) references public.plan_generation_jobs(id);
alter table public.plan_generation_jobs enable row level security;
revoke all on public.plan_generation_jobs from public,anon,authenticated;
grant select,insert,update on public.plan_generation_jobs to service_role;

insert into public.optimization_settings(key,value,description)
select defaults.key, defaults.value::jsonb, defaults.description
from (values
  ('mixed_spatial_buffer_meters','1500','Mixed launch candidate buffer in metres'),
  ('mixed_max_reports_per_anchor','5','Maximum launch satellites per anchor'),
  ('mixed_max_detour_minutes','30','Open-path insertion cap in minutes'),
  ('solver_time_limit_seconds','20','One bounded solve per planning batch'),
  ('solver_max_candidate_nodes','200','Maximum nodes in a solver batch'),
  ('mixed_bundle_reserve_pct','20','Generalist time reserved for satellites'),
  ('mixed_include_standalone_breached','true','Include remote breached Sweeper tasks'),
  ('breached_first','true','SLA-breached reports rank first'),
  ('sweeper_group_radius_meters','100','Sweeper grouping radius'),
  ('sweeper_max_reports_per_task','5','Sweeper report count limit'),
  ('planning_speed_kmh','20','Provisional route speed'),
  ('planning_circuity_factor','1.3','Provisional route distance factor'),
  ('bundle_proximity_bonus_max','15','Bundle-only MCDA proximity bonus'),
  ('mcda_weights','{"severity":0.4,"urgency":0.25,"report_count":0.15,"waiting_time":0.15,"weather":0.05}','Stable MCDA baseline weights')
) as defaults(key,value,description)
where not exists (select 1 from public.optimization_settings existing where existing.key=defaults.key);

commit;
