-- Slice A1: additive lifecycle foundation. Activation is a separate, one-time deployment step.
begin;
create schema if not exists workflow_private;
revoke all on schema workflow_private from public, anon, authenticated;
grant usage on schema workflow_private to service_role;

create table workflow_private.lifecycle_deployment (
  singleton boolean primary key default true check (singleton),
  activated_at timestamptz not null
);
create table workflow_private.historical_sla_reset (
  report_id uuid primary key,
  original_created_at timestamptz,
  original_deadline_at timestamptz,
  original_is_outlier boolean,
  reset_at timestamptz not null
);
alter table workflow_private.lifecycle_deployment enable row level security;
alter table workflow_private.historical_sla_reset enable row level security;
revoke all on all tables in schema workflow_private from public, anon, authenticated;
grant all on all tables in schema workflow_private to service_role;

alter table public.reports
  add column sla_started_at timestamptz,
  add column lifecycle_state text check (lifecycle_state in ('fresh','clustered','maturing','sla_breached','dispatched','closed')),
  add column matured_at timestamptz,
  add column breached_at timestamptz;
create index reports_lifecycle_open_idx on public.reports (lifecycle_state, deadline_at)
  where lifecycle_state is distinct from 'closed';

create function workflow_private.severity_tier(score integer)
returns text language sql immutable set search_path = ''
as $$
  select case when score is null then 'unknown'
    when score between 0 and 33 then 'low'
    when score between 34 and 66 then 'medium'
    when score between 67 and 100 then 'high'
    else 'invalid' end;
$$;

create function workflow_private.lifecycle_config()
returns table (normal_hours numeric, high_hours numeric, sla_hours numeric)
language plpgsql stable set search_path = ''
as $$
begin
  select (select (parameter_value->>'hours')::numeric from public.sweeper_configuration where parameter_name='maturation_threshold_hours'),
         (select (parameter_value->>'hours')::numeric from public.sweeper_configuration where parameter_name='high_severity_maturation_hours'),
         (select (parameter_value->>'hours')::numeric from public.sweeper_configuration where parameter_name='sla_threshold')
    into normal_hours, high_hours, sla_hours;
  if normal_hours is null or high_hours is null or sla_hours is null
     or not (0 < high_hours and high_hours < normal_hours and normal_hours < sla_hours and sla_hours <= 168) then
    raise exception 'Require 0 < high maturation < normal maturation < SLA <= 168 hours';
  end if;
  return next;
end;
$$;

create function workflow_private.derive_report_lifecycle(
  report_status text, cluster uuid, task uuid, clock_start timestamptz,
  deadline timestamptz, maturation_hours numeric, at_time timestamptz
) returns text language sql immutable set search_path = ''
as $$
  select case
    when report_status in ('resolved','completed','closed','rejected') then 'closed'
    when task is not null then 'dispatched'
    when cluster is not null then 'clustered'
    when at_time >= deadline then 'sla_breached'
    when at_time >= clock_start + maturation_hours * interval '1 hour' then 'maturing'
    else 'fresh' end;
$$;

-- Private definer trigger only: callers cannot edit SLA history or the derived state.
-- Public operational RPCs below remain SECURITY INVOKER and service-role-only.
create function workflow_private.apply_report_lifecycle()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  deployed timestamptz;
  cfg record;
  maturation numeric;
  stamp timestamptz := statement_timestamp();
begin
  select activated_at into deployed from workflow_private.lifecycle_deployment where singleton;
  if deployed is null then
    new.sla_started_at := null;
    new.lifecycle_state := null;
    new.matured_at := null;
    new.breached_at := null;
    return new;
  end if;
  select * into cfg from workflow_private.lifecycle_config();
  maturation := case when workflow_private.severity_tier(new.severity_score)='high'
    then cfg.high_hours else cfg.normal_hours end;
  if tg_op='INSERT' then
    new.sla_started_at := stamp;
    new.deadline_at := stamp + cfg.sla_hours * interval '1 hour';
    new.matured_at := null;
    new.breached_at := null;
  else
    -- An unresolved predeployment report receives the deployment clock exactly once.
    new.sla_started_at := coalesce(old.sla_started_at,
      case when old.status::text='unresolved' then deployed else coalesce(old.created_at, deployed) end);
    new.deadline_at := case when old.sla_started_at is not null then old.deadline_at
      when old.status::text='unresolved' then deployed + cfg.sla_hours * interval '1 hour'
      else coalesce(old.deadline_at, new.sla_started_at + cfg.sla_hours * interval '1 hour') end;
    new.matured_at := old.matured_at;
    new.breached_at := old.breached_at;
  end if;
  -- Include closure updates so completion at/after the deadline cannot erase a breach.
  -- Existing closed reports have no reconstructed cleanup/SLA history.
  if tg_op='INSERT' or coalesce(old.status::text,'unresolved') not in ('resolved','completed','closed','rejected') then
    if stamp >= new.sla_started_at + maturation * interval '1 hour' then
      new.matured_at := coalesce(new.matured_at, new.sla_started_at + maturation * interval '1 hour');
    end if;
    if stamp >= new.deadline_at then
      new.breached_at := coalesce(new.breached_at, new.deadline_at);
    end if;
  end if;
  new.lifecycle_state := workflow_private.derive_report_lifecycle(
    new.status::text,new.cluster_id,new.cleanup_task_id,new.sla_started_at,new.deadline_at,maturation,stamp);
  -- Temporary writable-column compatibility; legacy writers cannot override derived history.
  new.is_outlier := new.lifecycle_state in ('maturing','sla_breached');
  return new;
end;
$$;
create trigger zz_apply_report_lifecycle before insert or update on public.reports
  for each row execute function workflow_private.apply_report_lifecycle();

create function workflow_private.audit_report_lifecycle()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.lifecycle_state is null then return new; end if;
  if old.lifecycle_state is distinct from new.lifecycle_state
     or old.matured_at is distinct from new.matured_at
     or old.breached_at is distinct from new.breached_at then
    insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
    values ('REPORT_LIFECYCLE_CHANGE','REPORT',new.id::text,'system',
      jsonb_build_object('from',old.lifecycle_state,'to',new.lifecycle_state,
        'sla_started_at',new.sla_started_at,'matured_at',new.matured_at,'breached_at',new.breached_at));
    if old.breached_at is null and new.breached_at is not null then
      insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
      values ('SLA_BREACH_DETECTED','REPORT',new.id::text,'system',
        jsonb_build_object('breached_at',new.breached_at,'sla_started_at',new.sla_started_at));
    end if;
  end if;
  return new;
end;
$$;
create trigger zz_audit_report_lifecycle after update on public.reports
  for each row execute function workflow_private.audit_report_lifecycle();

create function public.activate_report_lifecycle(high_maturation_hours numeric, normal_maturation_hours numeric default 24)
returns jsonb language plpgsql security invoker set search_path = ''
as $$
declare deployed timestamptz; changed integer; cfg record;
begin
  perform pg_catalog.pg_advisory_xact_lock(72631008);
  select activated_at into deployed from workflow_private.lifecycle_deployment where singleton;
  if deployed is not null then
    return jsonb_build_object('activatedAt',deployed,'alreadyActivated',true,'resetCount',0);
  end if;
  -- Block concurrent report writes until the entire baseline and marker are committed.
  lock table public.reports in share row exclusive mode;
  insert into public.sweeper_configuration(parameter_name,parameter_value)
  values ('maturation_threshold_hours',jsonb_build_object('hours',normal_maturation_hours)),
    ('high_severity_maturation_hours',jsonb_build_object('hours',high_maturation_hours))
  on conflict (parameter_name) do update set parameter_value=excluded.parameter_value;
  select * into cfg from workflow_private.lifecycle_config();
  deployed := clock_timestamp();
  insert into workflow_private.lifecycle_deployment values (true,deployed);
  insert into workflow_private.historical_sla_reset
    select id,created_at,deadline_at,is_outlier,deployed from public.reports where status::text='unresolved';
  get diagnostics changed = row_count;
  update public.reports set sla_started_at = sla_started_at;
  insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
    values ('SLA_BASELINE_RESET','SYSTEM','report_lifecycle','system',
      jsonb_build_object('deployment_at',deployed,'reset_count',changed,'policy','grandfather_unresolved'));
  return jsonb_build_object('activatedAt',deployed,'alreadyActivated',false,'resetCount',changed);
end;
$$;

create function public.advance_report_lifecycle()
returns jsonb language plpgsql security invoker set search_path = ''
as $$
declare cfg record; changed integer; breaches jsonb;
begin
  if not pg_catalog.pg_try_advisory_xact_lock(72631008) then
    return jsonb_build_object('skipped',true,'changedCount',0,'newlyBreached','[]'::jsonb);
  end if;
  if not exists(select 1 from workflow_private.lifecycle_deployment) then
    raise exception 'Report lifecycle has not been activated';
  end if;
  select * into cfg from workflow_private.lifecycle_config();
  with candidates as materialized (
    select r.id,r.breached_at as old_breached from public.reports r
    where r.lifecycle_state is distinct from 'closed' and (
      r.lifecycle_state is distinct from workflow_private.derive_report_lifecycle(
        r.status::text,r.cluster_id,r.cleanup_task_id,r.sla_started_at,r.deadline_at,
        case when workflow_private.severity_tier(r.severity_score)='high' then cfg.high_hours else cfg.normal_hours end,statement_timestamp())
      or (r.breached_at is null and statement_timestamp() >= r.deadline_at)
      or (r.matured_at is null and statement_timestamp() >= r.sla_started_at +
        (case when workflow_private.severity_tier(r.severity_score)='high' then cfg.high_hours else cfg.normal_hours end) * interval '1 hour'))
    for update skip locked
  ), updated as (
    update public.reports r set updated_at=statement_timestamp() from candidates c where r.id=c.id
    returning r.id,r.breached_at,c.old_breached,r.sla_started_at
  )
  select count(*)::integer,coalesce(jsonb_agg(jsonb_build_object('id',u.id,
    'breachDuration',extract(epoch from(statement_timestamp()-u.sla_started_at))/3600,
    'timestamp',u.breached_at)) filter(where u.old_breached is null and u.breached_at is not null),'[]'::jsonb)
    into changed,breaches from updated u;
  insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
    values ('LIFECYCLE_RUN_COMPLETED','SYSTEM','report_lifecycle','system',
      jsonb_build_object('changedCount',changed,'newlyBreachedCount',jsonb_array_length(breaches)));
  return jsonb_build_object('skipped',false,'changedCount',changed,'newlyBreached',breaches);
end;
$$;

-- The old detector would bypass the grandfathered baseline; replace its body in this migration.
-- Keep its signature for older callers, but require the new baseline to exist.
create or replace function public.detect_sla_outliers()
returns table(report_id uuid,breach_duration numeric,flagged_at timestamptz)
language plpgsql security invoker set search_path = ''
as $$
declare result jsonb;
begin
  result := public.advance_report_lifecycle();
  return query select (v->>'id')::uuid,(v->>'breachDuration')::numeric,(v->>'timestamp')::timestamptz
    from jsonb_array_elements(result->'newlyBreached') v;
end;
$$;

create function workflow_private.validate_lifecycle_config()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if exists(select 1 from workflow_private.lifecycle_deployment) then
    perform * from workflow_private.lifecycle_config();
  end if;
  return null;
end;
$$;
create trigger zz_validate_lifecycle_config after insert or update or delete
  on public.sweeper_configuration for each statement
  execute function workflow_private.validate_lifecycle_config();

revoke all on all functions in schema workflow_private from public,anon,authenticated;
grant execute on all functions in schema workflow_private to service_role;
revoke all on function public.activate_report_lifecycle(numeric,numeric) from public,anon,authenticated;
revoke all on function public.advance_report_lifecycle() from public,anon,authenticated;
revoke all on function public.detect_sla_outliers() from public,anon,authenticated;
grant execute on function public.activate_report_lifecycle(numeric,numeric),public.advance_report_lifecycle(),public.detect_sla_outliers() to service_role;
commit;
