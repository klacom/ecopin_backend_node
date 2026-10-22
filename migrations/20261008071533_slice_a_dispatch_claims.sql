begin;
alter type public.cleanup_task_type add value if not exists 'Sweeper';
-- Existing consistency triggers run inside the service RPC's empty search path.
-- Qualify their table references so task creation and report regrouping work.
create or replace function public.check_task_outlier_consistency()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if exists(select 1 from public.clusters where id=any(new.cluster_ids) and is_outlier<>new.is_outlier) then
    raise exception 'Task is_outlier flag (%) must match all contained clusters',new.is_outlier;
  end if;
  return new;
end; $$;
create or replace function public.check_cluster_outlier_consistency()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if exists(select 1 from public.reports where cluster_id=new.id and is_outlier<>new.is_outlier) then
    raise exception 'Cluster is_outlier flag (%) must match all contained reports',new.is_outlier;
  end if;
  return new;
end; $$;
alter table public.field_crews
  add column supports_standard boolean not null default true,
  add column supports_sweeper boolean not null default false,
  add column speed_factor numeric not null default 1 check(speed_factor > 0 and speed_factor <= 3),
  add column service_time_factor numeric not null default 1 check(service_time_factor > 0 and service_time_factor <= 3);
alter table public.dispatch_plans
  add column mode text not null default 'standard' check(mode in ('standard','sweeper')),
  add column settings_snapshot jsonb not null default '{}',
  add column optimization_run_id uuid references public.optimization_runs(id),
  add column routing_attempts integer not null default 0 check(routing_attempts between 0 and 3);
alter table public.dispatch_plan_items
  alter column cluster_id drop not null,
  add column report_id uuid references public.reports(id),
  add column report_ids uuid[] not null default '{}',
  add column item_type text not null default 'cluster' check(item_type in ('cluster','report')),
  add column group_key text not null default gen_random_uuid()::text,
  add column planned_crew_id uuid references public.field_crews(id),
  add column estimated_work_minutes integer not null default 0 check(estimated_work_minutes>=0),
  add column priority_score numeric,
  add column crew_snapshot jsonb not null default '{}';
alter table public.dispatch_plan_items add constraint dispatch_item_target check(
  (item_type='cluster' and cluster_id is not null and report_id is null)
  or (item_type='report' and report_id is not null and cluster_id is null));
create unique index dispatch_unique_cluster on public.dispatch_plan_items(dispatch_plan_id,cluster_id) where cluster_id is not null;
create unique index dispatch_unique_report on public.dispatch_plan_items(dispatch_plan_id,report_id) where report_id is not null;
create unique index dispatch_unique_group on public.dispatch_plan_items(dispatch_plan_id,group_key);
alter table public.cleanup_tasks
  add column source_plan_id uuid references public.dispatch_plans(id),
  add column source_group_key text,
  add column assigned_field_crew_id uuid references public.field_crews(id),
  add column estimated_work_minutes integer not null default 0 check(estimated_work_minutes>=0),
  add column dispatch_kind text not null default 'standard' check(dispatch_kind in ('standard','sweeper')),
  add column route_status text not null default 'ready' check(route_status in ('needs_replan','ready','expired')),
  add column routing_deadline_at timestamptz,
  add column routing_escalated_at timestamptz,
  add column failure_class text check(failure_class in ('transient','site','safety','unclassified')),
  add column failure_reason text;
create unique index task_source_group on public.cleanup_tasks(source_plan_id,source_group_key) where source_plan_id is not null;
create index task_unpublished_expiry on public.cleanup_tasks(routing_deadline_at) where route_status='needs_replan';
create table public.dispatch_group_commits(
  dispatch_plan_id uuid not null references public.dispatch_plans(id),
  group_key text not null,
  result jsonb not null,
  committed_at timestamptz not null default now(),
  primary key(dispatch_plan_id,group_key)
);
alter table public.dispatch_group_commits enable row level security;
revoke all on public.dispatch_group_commits from public,anon,authenticated;
grant select,insert on public.dispatch_group_commits to service_role;

create function workflow_private.immutable_group_result() returns trigger
language plpgsql set search_path='' as $$ begin
  raise exception 'Dispatch group results are immutable';
end; $$;
create trigger immutable_group_result before update or delete on public.dispatch_group_commits
  for each row execute function workflow_private.immutable_group_result();

create function workflow_private.require_desk_actor(actor uuid) returns void
language plpgsql stable set search_path='' as $$
begin
  if not exists(select 1 from public.profiles where id=actor and role::text in ('admin','officer')) then
    raise exception 'Desk officer access required' using errcode='42501';
  end if;
end; $$;

create function public.save_dispatch_plan(actor uuid, plan_mode text, settings jsonb, items jsonb, available_crews integer, capacity_minutes integer)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare plan public.dispatch_plans; item jsonb; ids uuid[]; duplicate_count integer;
begin
  perform workflow_private.require_desk_actor(actor);
  if plan_mode is null or plan_mode not in ('standard','sweeper') or jsonb_typeof(items) is distinct from 'array'
    or jsonb_array_length(items)>400 or available_crews<0 or capacity_minutes<0 then
    raise exception 'Invalid Slice A plan';
  end if;
  insert into public.dispatch_plans(created_by,mode,settings_snapshot,total_crews_available,total_capacity_minutes,status)
    values(actor,plan_mode,settings,available_crews,capacity_minutes,'draft') returning * into plan;
  for item in select value from jsonb_array_elements(items) loop
    select coalesce(array_agg(v::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(item->'report_ids') v;
    if cardinality(ids)=0 or cardinality(ids)<>(select count(distinct x) from unnest(ids) x) then
      raise exception 'Plan groups require distinct report snapshots';
    end if;
    if item->>'item_type'='report' and ids<>array[(item->>'report_id')::uuid] then raise exception 'Standalone report snapshot must match target'; end if;
    if (item->>'estimated_work_minutes')::integer<1 or (item->>'estimated_duration_minutes')::integer<(item->>'estimated_work_minutes')::integer then raise exception 'Invalid task estimate'; end if;
    if (plan_mode='standard' and item->>'item_type'<>'cluster')
      or (plan_mode='sweeper' and item->>'item_type'<>'report') then
      raise exception 'Plan item does not match mode';
    end if;
    insert into public.dispatch_plan_items(dispatch_plan_id,cluster_id,report_id,report_ids,item_type,group_key,
      planned_crew_id,is_selected,reason,estimated_duration_minutes,priority_score,estimated_work_minutes,crew_snapshot)
    values(plan.id,(item->>'cluster_id')::uuid,(item->>'report_id')::uuid,ids,item->>'item_type',item->>'group_key',
      (item->>'planned_crew_id')::uuid,(item->>'is_selected')::boolean,item->>'reason',
      (item->>'estimated_duration_minutes')::integer,(item->>'priority_score')::numeric,(item->>'estimated_work_minutes')::integer,coalesce(item->'crew_snapshot','{}'::jsonb));
  end loop;
  select count(*)-count(distinct report) into duplicate_count
    from public.dispatch_plan_items i cross join lateral unnest(i.report_ids) report where i.dispatch_plan_id=plan.id;
  if duplicate_count<>0 then raise exception 'Report appears in multiple plan groups'; end if;
  return to_jsonb(plan);
end; $$;

create function public.commit_dispatch_plan(plan_id uuid, actor uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  plan public.dispatch_plans; item public.dispatch_plan_items; crew public.field_crews;
  anchor public.clusters; task public.cleanup_tasks; locked_ids uuid[]; result jsonb;
  results jsonb:='[]'; budget numeric; busy numeric; busy_count integer; shift_minutes numeric;
  settings jsonb; claim_count integer; task_ids uuid[]:='{}'; group_error text;
begin
  perform workflow_private.require_desk_actor(actor);
  select * into plan from public.dispatch_plans where id=plan_id for update;
  if not found then raise exception 'Plan not found' using errcode='P0002'; end if;
  if plan.status::text='discarded' then raise exception 'Plan is discarded'; end if;
  settings := plan.settings_snapshot;
  -- Stable lock order across plans prevents inversions when their crew mappings differ.
  perform id from public.field_crews where id in (select planned_crew_id from public.dispatch_plan_items where dispatch_plan_id=plan_id and is_selected) order by id for update;
  for item in select * from public.dispatch_plan_items where dispatch_plan_id=plan_id and is_selected order by group_key loop
    select c.result into result from public.dispatch_group_commits c where c.dispatch_plan_id=plan_id and c.group_key=item.group_key;
    if found then
      results:=results||jsonb_build_array(result);
      if result->>'task_id' is not null then task_ids:=array_append(task_ids,(result->>'task_id')::uuid); end if;
      continue;
    end if;
    group_error:=null;
    -- Subtransaction releases locks and rolls back every write if any mandatory member is stale.
    begin
      if cardinality(item.report_ids)=0 then raise exception 'legacy_plan_requires_regeneration'; end if;
      select * into crew from public.field_crews where id=item.planned_crew_id for update;
      if not found or crew.availability_status::text<>'available'
         or (plan.mode='standard' and not crew.supports_standard)
         or (plan.mode='sweeper' and not crew.supports_sweeper) then
        raise exception 'crew_unavailable';
      end if;
      if coalesce(cardinality(crew.member_profile_ids),0)=0 and crew.team_lead_profile_id is null then
        raise exception 'crew_has_no_members';
      end if;
      if (item.crew_snapshot->>'speed_factor')::numeric is distinct from crew.speed_factor or (item.crew_snapshot->>'service_time_factor')::numeric is distinct from crew.service_time_factor then raise exception 'crew_timing_changed'; end if;
      if crew.shift_start is null or crew.shift_end is null then raise exception 'crew_unavailable'; end if;
      shift_minutes:=extract(epoch from(crew.shift_end-crew.shift_start))/60;
      if shift_minutes<0 then shift_minutes:=shift_minutes+1440; end if;
      budget:=greatest(0,(shift_minutes-coalesce((settings->>'break_duration_min')::numeric,60)+coalesce((settings->>'overtime_tolerance_min')::numeric,15))*coalesce((settings->>'capacity_utilization')::numeric,1));
      select coalesce(sum(coalesce(estimated_duration_min,60)),0),count(*) into busy,busy_count from public.cleanup_tasks
        where (assigned_field_crew_id=crew.id or coalesce(assigned_crew_ids,'{}'::uuid[]) && (coalesce(crew.member_profile_ids,'{}'::uuid[]) || array_remove(array[crew.team_lead_profile_id],null)))
          and status::text not in ('completed','cancelled');
      if busy+item.estimated_duration_minutes>budget or busy_count>=least(coalesce(crew.max_tasks_per_shift,10),coalesce((settings->>'max_tasks_per_shift')::integer,15)) then
        raise exception 'crew_capacity_changed';
      end if;
      if item.item_type='cluster' then
        select * into anchor from public.clusters where id=item.cluster_id for update skip locked;
        if not found or anchor.status::text not in ('new','unresolved','prioritized','queued','monitoring') then raise exception 'stale_anchor'; end if;
        if exists(select 1 from public.reports where cluster_id=anchor.id and status::text not in ('resolved','completed','closed','rejected')
          and not(id=any(item.report_ids))) then raise exception 'anchor_membership_changed'; end if;
      end if;
      select coalesce(array_agg(r.id order by r.id),'{}'::uuid[]) into locked_ids from (
        select id from public.reports r where id=any(item.report_ids) and cleanup_task_id is null
          and status::text not in ('resolved','completed','closed','rejected')
          and ((item.item_type='cluster' and cluster_id=item.cluster_id)
             or (item.item_type='report' and cluster_id is null and lifecycle_state in ('maturing','sla_breached')))
        order by id for update skip locked
      ) r;
      if cardinality(locked_ids)<>cardinality(item.report_ids) then raise exception 'stale_group'; end if;
      insert into public.cleanup_tasks(cluster_id,cluster_ids,report_ids,report_sequence,title,status,task_type,
        estimated_duration_min,created_by,source_plan_id,source_group_key,assigned_field_crew_id,dispatch_kind,
        route_status,routing_deadline_at,scheduled_date,location,is_outlier,estimated_work_minutes,priority_score)
      values(item.cluster_id,case when item.cluster_id is null then '{}'::uuid[] else array[item.cluster_id] end,
        locked_ids,locked_ids,case when plan.mode='sweeper' then 'Sweeper pickup' else 'Cluster cleanup' end,'pending',
        (case when plan.mode='sweeper' then 'Sweeper' when anchor.recommended_task_type='Scouting' then case when exists(select 1 from public.reports where id=any(locked_ids) and validation_status::text is distinct from 'approved') then 'Verification' else 'Cleanup' end
          when anchor.recommended_task_type in ('Cleanup','Investigation','Verification','Emergency Response','Reinspection','Monitoring','Escalation') then anchor.recommended_task_type else 'Cleanup' end)::public.cleanup_task_type,
        item.estimated_duration_minutes,actor,plan_id,item.group_key,crew.id,plan.mode,'needs_replan',now()+interval '30 minutes',plan.planned_date,
        (select location from public.reports where id=locked_ids[1]),plan.mode='sweeper',item.estimated_work_minutes,item.priority_score) returning * into task;
      update public.reports set cleanup_task_id=task.id,updated_at=now() where id=any(locked_ids) and cleanup_task_id is null;
      get diagnostics claim_count=row_count;
      if claim_count<>cardinality(locked_ids) then raise exception 'stale_group'; end if;
      if item.cluster_id is not null then update public.clusters set status='scheduled' where id=item.cluster_id; end if;
      result:=jsonb_build_object('status','committed','group_key',item.group_key,'task_id',task.id,'report_ids',locked_ids,'crew_id',crew.id);
      task_ids:=array_append(task_ids,task.id);
    exception when raise_exception then
      get stacked diagnostics group_error=message_text;
      if group_error not in ('legacy_plan_requires_regeneration','crew_unavailable','crew_timing_changed','crew_has_no_members','crew_capacity_changed','stale_anchor','anchor_membership_changed','stale_group','dispatch_blocked') then raise; end if;
      result:=jsonb_build_object('status','skipped','group_key',item.group_key,'reason',group_error);
    end;
    insert into public.dispatch_group_commits(dispatch_plan_id,group_key,result) values(plan_id,item.group_key,result);
    results:=results||jsonb_build_array(result);
  end loop;
  update public.dispatch_plans set status='approved' where id=plan_id;
  return jsonb_build_object('plan_id',plan_id,'results',results,'tasks',
    coalesce((select jsonb_agg(to_jsonb(t)) from public.cleanup_tasks t where id=any(task_ids)),'[]'::jsonb));
end; $$;

revoke all on function public.save_dispatch_plan(uuid,text,jsonb,jsonb,integer,integer),public.commit_dispatch_plan(uuid,uuid) from public,anon,authenticated;
grant execute on function public.save_dispatch_plan(uuid,text,jsonb,jsonb,integer,integer),public.commit_dispatch_plan(uuid,uuid) to service_role;
revoke all on all functions in schema workflow_private from public,anon,authenticated;
grant execute on all functions in schema workflow_private to service_role;
commit;
