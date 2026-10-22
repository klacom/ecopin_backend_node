create schema extensions;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid; $$;
grant usage on schema auth to authenticated,service_role;
create type public.crew_availability_status as enum ('available','on_route','off_shift','disabled');
create extension postgis with schema extensions;
set search_path=public,extensions;
create type public.report_issue_type as enum ('waste','flooding','pollution','infrastructure','illegal_logging','pending','others');
create type public.cluster_severity as enum ('low','medium','high');
create type public.route_waypoint_type as enum ('depot_start','task','depot_end');
create type public.cleanup_task_status as enum ('created','pending','in_progress','partially_completed','completed','cancelled');
create type public.cleanup_task_type as enum ('Cleanup','Investigation','Verification','Emergency Response','Reinspection','Monitoring','Escalation','Deferred');
create type public.cluster_status as enum ('new','unresolved','prioritized','queued','scheduled','in_progress','resolved','needs_verification','monitoring','deferred','escalated','completed','closed');
create type public.dispatch_plan_status as enum ('draft','approved','discarded');
create type public.role as enum ('citizen','lgu','admin','officer','field_crew');
create table public.profiles(
id uuid primary key,
full_name text,
created_at timestamptz default now(),
role role default 'citizen'::role,
avatar_url text,
data_consent bool,
suspended_until timestamptz,
strike_count int4 default 0,
last_strike_at timestamptz,
is_email_verified bool default false,
require_password_change bool default false);
create table public.clusters(
id uuid primary key default gen_random_uuid(),
center extensions.geometry not null,
radius_meters numeric default 50,
report_count int4 not null,
issue_type report_issue_type,
severity cluster_severity,
status cluster_status default 'unresolved'::cluster_status,
created_at timestamptz default now(),
updated_at timestamptz default now(),
priority_score numeric,
priority text,
estimated_effort_minutes int4 default 60,
recommended_task_type text default 'Cleanup'::text,
is_outlier bool default false,
label text);
create table public.cleanup_tasks(
id uuid primary key default gen_random_uuid(),
cluster_id uuid,
lgu_user_id uuid,
title text,
status cleanup_task_status default 'created'::cleanup_task_status,
before_photo_url text,
after_photo_url text,
notes text,
created_at timestamptz default now(),
completed_at timestamptz,
created_by uuid,
description text,
is_custom bool default false,
report_ids uuid[],
assigned_crew_ids uuid[],
assigned_at timestamptz,
assigned_by uuid,
last_assigned_at timestamptz,
priority text,
priority_score numeric,
crew_route_id uuid,
sequence_in_route int4,
estimated_duration_min int4,
task_type cleanup_task_type default 'Cleanup'::cleanup_task_type,
cluster_ids uuid[] default '{}'::uuid[],
required_resources text,
expected_action text,
scheduled_date date,
completion_result text,
completion_notes text,
report_sequence uuid[] default '{}'::uuid[],
fc_version int8 not null default 0,
before_photo_hash text,
after_photo_hash text,
location extensions.geography,
street_address text,
is_outlier bool default false);
create table public.field_crews(
id uuid primary key default gen_random_uuid(),
name text not null,
team_lead_profile_id uuid,
member_profile_ids uuid[] default '{}'::uuid[],
depot_location extensions.geography,
shift_start time not null default '08:00:00'::time without time zone,
shift_end time not null default '17:00:00'::time without time zone,
max_tasks_per_shift int4 default 10,
availability_status crew_availability_status default 'available'::crew_availability_status,
created_at timestamptz default now(),
updated_at timestamptz default now());
create table public.optimization_runs(
id uuid primary key default gen_random_uuid(),
triggered_by uuid,
status text default 'draft'::text,
criteria jsonb not null,
weather_condition text default 'normal'::text,
traffic_condition text default 'low'::text,
num_tasks_optimized int4 default 0,
num_crews int4 default 2,
total_estimated_distance_meters numeric,
total_estimated_duration_min numeric,
error_message text,
approved_by uuid,
approved_at timestamptz,
created_at timestamptz default now());
create table public.dispatch_plans(
id uuid primary key default gen_random_uuid(),
planned_date date not null default CURRENT_DATE,
total_crews_available int4 not null default 0,
total_capacity_minutes int4 not null default 0,
status dispatch_plan_status default 'draft'::dispatch_plan_status,
created_at timestamptz default now(),
created_by uuid);
create table public.dispatch_plan_items(
id uuid primary key default gen_random_uuid(),
dispatch_plan_id uuid not null,
cluster_id uuid not null,
is_selected bool not null default false,
reason text,
estimated_duration_minutes int4,
created_at timestamptz default now());
create table public.crew_routes(
id uuid primary key default gen_random_uuid(),
optimization_run_id uuid not null,
crew_id uuid not null,
start_depot extensions.geography not null,
end_depot extensions.geography not null,
total_distance_meters numeric,
total_duration_min numeric,
task_count int4 default 0,
weather_snapshot jsonb,
traffic_snapshot jsonb,
created_at timestamptz default now());
create table public.optimization_settings(
id uuid primary key default gen_random_uuid(),
key text not null,
value jsonb not null,
description text,
updated_by uuid,
updated_at timestamptz default now());
create table public.optimization_templates(id uuid primary key default gen_random_uuid(),name text,description text,created_by uuid,is_default bool default false,settings jsonb default '{}',created_at timestamptz default now(),updated_at timestamptz default now());
create table public.work_time_configuration(report_type varchar primary key,work_time_minutes int not null,updated_at timestamptz default now());
alter table public.reports add column location extensions.geography(Point,4326),add column issue_type public.report_issue_type default 'waste',add column urgency_score integer default 1,add column lgu_resolved_at timestamptz,add column fc_version bigint not null default 0,add column notes text,add column stage text,add column validation_status text,add column before_photo_url text,add column after_photo_url text,add column before_photo_hash text,add column after_photo_hash text;
alter table public.reports add constraint reports_cluster_id_fkey foreign key(cluster_id) references public.clusters(id) on delete cascade;
alter table public.reports add column user_id uuid,add column title text,add column description text,add column on_private_property boolean,add column property_owner_consent_status text,add column idempotency_key text,add column satisfaction_rating int,add column citizen_closed_at timestamptz,add column is_overdue bool,add column ra9003_category text,add column ml_predicted_class text,add column ml_confidence real,add column ml_probabilities jsonb;
create type public.sync_entity_type as enum ('report','task','cluster','dispatch_plan');
create type public.sync_operation_type as enum ('fc.report.update_status','fc.report.update_lifecycle_stage','fc.report.update_validation','fc.report.update_details','fc.note.add','fc.task.mark_complete','fc.photo.upload_before','fc.photo.upload_after','fc.photo.delete','task_update','report_create','report_update');
create table public.fc_operation_log(operation_id text primary key,user_id uuid,operation_type public.sync_operation_type not null,entity_id text,entity_type public.sync_entity_type,status text,result jsonb,created_at timestamptz default now(),expires_at timestamptz default now()+interval '30 days');
create table public.fc_conflict_audit(id uuid default gen_random_uuid(),operation_id text,user_id uuid,operation_type public.sync_operation_type,entity_id text,entity_type public.sync_entity_type,outcome text,client_base_version bigint,server_version bigint,payload jsonb,server_state_snapshot jsonb,reason text,created_at timestamptz default now());
create table public.response_log(id uuid primary key default gen_random_uuid(),report_id uuid,user_id uuid,action_type text,action_details text,created_at timestamptz default now());
create view public.reports_view as select id,user_id,title,description,issue_type,location,validation_status,status,
  cluster_id,created_at,updated_at,notes,before_photo_url,after_photo_url,on_private_property,
  property_owner_consent_status,stage,satisfaction_rating,lgu_resolved_at,citizen_closed_at,
  is_overdue,severity_score,urgency_score,ra9003_category,ml_predicted_class,
  ml_confidence,ml_probabilities,deadline_at,is_outlier from public.reports;
grant all on public.reports_view to anon,authenticated;
create table public.route_waypoints(id uuid primary key default gen_random_uuid(),crew_route_id uuid,sequence_order integer,latitude numeric,longitude numeric,cleanup_task_id uuid,waypoint_type public.route_waypoint_type,distance_from_previous_meters numeric,estimated_time_from_previous_min numeric,created_at timestamptz default now(),polyline jsonb);
grant all on all tables in schema public to service_role;
create function public.get_auth_user_role() returns public.role language sql stable security definer set search_path=public as $$ select role from public.profiles where id=auth.uid(); $$;
grant select on all tables in schema public to authenticated;
grant usage on schema extensions to service_role;

-- Preserve the live outlier consistency checks in compatibility fixtures.
CREATE OR REPLACE FUNCTION public.check_cluster_outlier_consistency()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    mismatched_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO mismatched_count
    FROM reports
    WHERE cluster_id = NEW.id AND is_outlier != NEW.is_outlier;

    IF mismatched_count > 0 THEN
        RAISE EXCEPTION 'Cluster is_outlier flag (%) must match all contained reports', NEW.is_outlier;
    END IF;

    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.check_task_outlier_consistency()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    mismatched_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO mismatched_count
    FROM clusters
    WHERE id = ANY(NEW.cluster_ids) AND is_outlier != NEW.is_outlier;

    IF mismatched_count > 0 THEN
        RAISE EXCEPTION 'Task is_outlier flag (%) must match all contained clusters', NEW.is_outlier;
    END IF;

    RETURN NEW;
END;
$function$;

create trigger trigger_check_cluster_outlier before update of is_outlier on public.clusters for each row execute function public.check_cluster_outlier_consistency();
create trigger trigger_check_task_outlier before insert or update of is_outlier,cluster_ids on public.cleanup_tasks for each row execute function public.check_task_outlier_consistency();
