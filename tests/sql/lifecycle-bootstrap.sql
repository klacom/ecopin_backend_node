\set ON_ERROR_STOP on
do $$ begin
  if not exists(select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role bypassrls; end if;
end; $$;
create type public.report_status as enum ('unresolved','in_progress','resolved','pending_owner_consent','waiting_for_feedback','closed','completed','rejected');
create table public.reports (
  id uuid primary key default gen_random_uuid(), status public.report_status default 'unresolved',
  created_at timestamptz default now(), updated_at timestamptz default now(),
  deadline_at timestamptz, severity_score integer check(severity_score between 0 and 100),
  cluster_id uuid, cleanup_task_id uuid, is_outlier boolean default false
);
create table public.sweeper_configuration(parameter_name varchar primary key,parameter_value jsonb not null);
insert into public.sweeper_configuration values('sla_threshold','{"hours":48}');
create table public.sweeper_audit_log(
  id serial primary key,event_type varchar not null,entity_type varchar not null,
  entity_id varchar not null,user_id varchar,event_data jsonb,created_at timestamptz default now()
);
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
-- Existing trigger runs before the new lifecycle trigger, as on the live schema.
create function public.calculate_report_deadline() returns trigger language plpgsql as $$
begin
  new.deadline_at := new.created_at + case
    when new.severity_score=5 then interval '24 hours'
    when new.severity_score=4 then interval '48 hours'
    when new.severity_score in (2,3) then interval '72 hours'
    else interval '7 days' end;
  return new;
end; $$;
create trigger set_report_deadline before insert or update of severity_score on public.reports
  for each row execute function public.calculate_report_deadline();
