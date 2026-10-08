-- Phase 12: retire legacy outlier flags after all clients use lifecycle and dispatch kind.
-- Keep function replacements and the column drop in one transaction.
begin;
set local lock_timeout = '10s';

-- The view depends on reports.is_outlier; no other relation depends on this view.
drop view public.reports_view;

-- Trigger bodies must stop writing the retired report column before it is removed.

create or replace function workflow_private.apply_report_lifecycle()
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
  return new;
end;
$$;


create or replace function public.activate_report_lifecycle(high_maturation_hours numeric, normal_maturation_hours numeric default 24)
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
    select id,created_at,deadline_at,(lifecycle_state in ('maturing','sla_breached')),deployed from public.reports where status::text='unresolved';
  get diagnostics changed = row_count;
  update public.reports set sla_started_at = sla_started_at;
  insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
    values ('SLA_BASELINE_RESET','SYSTEM','report_lifecycle','system',
      jsonb_build_object('deployment_at',deployed,'reset_count',changed,'policy','grandfather_unresolved'));
  return jsonb_build_object('activatedAt',deployed,'alreadyActivated',false,'resetCount',changed);
end;
$$;


create or replace function public.commit_dispatch_plan(plan_id uuid, actor uuid)
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
        route_status,routing_deadline_at,scheduled_date,location,estimated_work_minutes,priority_score)
      values(item.cluster_id,case when item.cluster_id is null then '{}'::uuid[] else array[item.cluster_id] end,
        locked_ids,locked_ids,case when plan.mode='sweeper' then 'Sweeper pickup' else 'Cluster cleanup' end,'pending',
        (case when plan.mode='sweeper' then 'Sweeper' when anchor.recommended_task_type='Scouting' then case when exists(select 1 from public.reports where id=any(locked_ids) and validation_status::text is distinct from 'approved') then 'Verification' else 'Cleanup' end
          when anchor.recommended_task_type in ('Cleanup','Investigation','Verification','Emergency Response','Reinspection','Monitoring','Escalation') then anchor.recommended_task_type else 'Cleanup' end)::public.cleanup_task_type,
        item.estimated_duration_minutes,actor,plan_id,item.group_key,crew.id,plan.mode,'needs_replan',now()+interval '30 minutes',plan.planned_date,
        (select location from public.reports where id=locked_ids[1]),item.estimated_work_minutes,item.priority_score) returning * into task;
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


create or replace function public.commit_mixed_dispatch_plan(plan_id uuid, actor uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare plan public.dispatch_plans; anchor public.dispatch_plan_items; satellite public.dispatch_plan_items;
  crew public.field_crews; task public.cleanup_tasks; result jsonb; results jsonb:='[]'::jsonb;
  mandatory_ids uuid[]; satellite_ids uuid[]; locked_ids uuid[]; cluster_ids uuid[];
  omitted_ids uuid[]; member_count integer; claimed integer; reason text;
  group_minutes numeric; group_volume numeric; group_weight numeric; busy_minutes numeric; busy_count integer;
  busy_volume numeric; busy_weight numeric; budget numeric; shift_minutes numeric;
begin
  perform workflow_private.require_desk_actor(actor);
  select * into plan from public.dispatch_plans where id=plan_id for update;
  if not found then raise exception 'Plan not found'; end if;
  if plan.mode<>'mixed' then raise exception 'Mixed plan required'; end if;
  if plan.status::text='discarded' then raise exception 'Plan discarded'; end if;
  if not exists(select 1 from public.plan_generation_jobs j where j.id=plan.generation_job_id
      and j.status='completed' and j.plan_id=plan.id) then raise exception 'Planning job is incomplete'; end if;
  if jsonb_typeof(plan.route_proposal->'routes') is distinct from 'array' then raise exception 'Validated route proposal required'; end if;
  perform id from public.field_crews where id in
    (select planned_crew_id from public.dispatch_plan_items where dispatch_plan_id=plan_id and is_selected)
    order by id for update;
  for anchor in select distinct on (group_key) * from public.dispatch_plan_items
      where dispatch_plan_id=plan_id and is_selected and item_type in ('cluster','report')
      order by group_key,id loop
    select c.result into result from public.dispatch_group_commits c
      where c.dispatch_plan_id=plan_id and c.group_key=anchor.group_key;
    if found then results:=results||jsonb_build_array(result); continue; end if;
    reason:=null;
    begin
      select * into crew from public.field_crews where id=anchor.planned_crew_id for update;
      if not found or crew.availability_status::text<>'available'
        or (anchor.item_type='cluster' and not crew.supports_standard)
        or (anchor.item_type='report' and not crew.supports_sweeper) then raise exception 'crew_unavailable'; end if;
      if coalesce(cardinality(crew.member_profile_ids),0)=0 and crew.team_lead_profile_id is null then
        raise exception 'crew_has_no_members'; end if;
      if (anchor.crew_snapshot->>'speed_factor')::numeric is distinct from crew.speed_factor
        or (anchor.crew_snapshot->>'service_time_factor')::numeric is distinct from crew.service_time_factor then
        raise exception 'crew_timing_changed'; end if;
      if crew.max_volume_m3 is null or crew.max_weight_kg is null
        or crew.starting_volume_m3 is null or crew.starting_weight_kg is null then
        raise exception 'unknown_load'; end if;
      cluster_ids:=case when anchor.item_type='cluster' then
        coalesce(nullif(anchor.cluster_ids,'{}'::uuid[]),array[anchor.cluster_id]) else '{}'::uuid[] end;
      if anchor.item_type='cluster' then
        select count(*) into member_count from (
          select c.id from public.clusters c where c.id=any(cluster_ids)
            and c.status::text in ('new','unresolved','prioritized','queued','monitoring')
            and not exists(select 1 from public.dispatch_access_blocks b where b.cluster_id=c.id and b.cleared_at is null)
            order by c.id for update skip locked
        ) locked_clusters;
        if member_count<>cardinality(cluster_ids) then raise exception 'stale_anchor'; end if;
        if exists(select 1 from public.reports r where r.cluster_id=any(cluster_ids)
          and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')
          and not(r.id=any(anchor.report_ids))) then raise exception 'anchor_membership_changed'; end if;
      end if;
      select coalesce(array_agg(r.id order by r.id),'{}'::uuid[]) into mandatory_ids from (
        select id from public.reports r where id=any(anchor.report_ids) and cleanup_task_id is null
          and status::text not in ('resolved','completed','closed','rejected')
          and ((anchor.item_type='cluster' and cluster_id=any(cluster_ids))
             or (anchor.item_type='report' and cluster_id is null and lifecycle_state in ('maturing','sla_breached')))
          and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null)
          order by id for update skip locked
      ) r;
      if cardinality(mandatory_ids)<>cardinality(anchor.report_ids) then raise exception 'stale_anchor'; end if;
      satellite_ids:='{}'::uuid[]; omitted_ids:='{}'::uuid[];
      for satellite in select * from public.dispatch_plan_items
        where dispatch_plan_id=plan_id and group_key=anchor.group_key and item_type='bundled_report' and is_selected
        order by bundle_order,id loop
        if satellite.planned_crew_id is distinct from crew.id then raise exception 'crew_assignment_changed'; end if;
        select array_agg(r.id) into locked_ids from (
          select id from public.reports r where r.id=satellite.report_id and r.cleanup_task_id is null
            and r.cluster_id is null and r.lifecycle_state in ('maturing','sla_breached')
            and r.status::text='unresolved'
            and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null)
            for update skip locked
        ) r;
        if locked_ids is null then
          omitted_ids:=array_append(omitted_ids,satellite.report_id);
          update public.dispatch_plan_items set commit_disposition='omitted',commit_reason='satellite_unavailable'
            where id=satellite.id;
        else
          satellite_ids:=array_append(satellite_ids,satellite.report_id);
        end if;
      end loop;
      group_minutes:=anchor.estimated_duration_minutes+coalesce((select sum(i.estimated_duration_minutes)
        from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id and i.group_key=anchor.group_key
          and i.report_id=any(satellite_ids)),0);
      group_volume:=anchor.estimated_volume_m3+coalesce((select sum(i.estimated_volume_m3)
        from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id and i.group_key=anchor.group_key
          and i.report_id=any(satellite_ids)),0);
      group_weight:=anchor.estimated_weight_kg+coalesce((select sum(i.estimated_weight_kg)
        from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id and i.group_key=anchor.group_key
          and i.report_id=any(satellite_ids)),0);
      if group_volume is null or group_weight is null then raise exception 'unknown_load'; end if;
      select coalesce(sum(coalesce(estimated_duration_min,60)),0),count(*),
        coalesce(sum(estimated_volume_m3),0),coalesce(sum(estimated_weight_kg),0)
        into busy_minutes,busy_count,busy_volume,busy_weight from public.cleanup_tasks
        where assigned_field_crew_id=crew.id and status::text not in ('completed','cancelled');
      if exists(select 1 from public.cleanup_tasks t where t.assigned_field_crew_id=crew.id
        and t.status::text not in ('completed','cancelled')
        and (t.estimated_volume_m3 is null or t.estimated_weight_kg is null)) then
        raise exception 'unknown_load'; end if;
      shift_minutes:=extract(epoch from(crew.shift_end-crew.shift_start))/60;
      if shift_minutes<0 then shift_minutes:=shift_minutes+1440; end if;
      budget:=greatest(0,(shift_minutes-coalesce((plan.settings_snapshot->>'break_duration_min')::numeric,60)
        +coalesce((plan.settings_snapshot->>'overtime_tolerance_min')::numeric,15))
        *coalesce((plan.settings_snapshot->>'capacity_utilization')::numeric,1));
      if busy_minutes+group_minutes>budget or busy_count>=least(coalesce(crew.max_tasks_per_shift,10),
        coalesce((plan.settings_snapshot->>'max_tasks_per_shift')::integer,15)) then
        raise exception 'crew_capacity_changed'; end if;
      if crew.starting_volume_m3+busy_volume+group_volume>crew.max_volume_m3 then raise exception 'capacity_volume'; end if;
      if crew.starting_weight_kg+busy_weight+group_weight>crew.max_weight_kg then raise exception 'capacity_weight'; end if;
      insert into public.cleanup_tasks(cluster_id,cluster_ids,report_ids,report_sequence,satellite_report_ids,
        title,status,task_type,estimated_duration_min,estimated_work_minutes,created_by,source_plan_id,
        source_group_key,assigned_field_crew_id,dispatch_kind,route_status,routing_deadline_at,
        scheduled_date,location,priority_score,estimated_volume_m3,estimated_weight_kg)
      values(anchor.cluster_id,cluster_ids,mandatory_ids||satellite_ids,mandatory_ids||satellite_ids,satellite_ids,
        case when anchor.item_type='cluster' then 'Mixed cluster cleanup' else 'Sweeper pickup' end,
        'pending',case when anchor.item_type='cluster' then 'Mixed'::public.cleanup_task_type else 'Sweeper'::public.cleanup_task_type end,
        ceil(group_minutes),anchor.estimated_work_minutes+coalesce((select sum(i.estimated_work_minutes)
          from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id and i.group_key=anchor.group_key
            and i.report_id=any(satellite_ids)),0),actor,plan_id,anchor.group_key,crew.id,'mixed',
        'needs_replan',now()+interval '30 minutes',plan.planned_date,
        (select location from public.reports where id=mandatory_ids[1]),
        anchor.priority_score,group_volume,group_weight) returning * into task;
      update public.reports set cleanup_task_id=task.id,updated_at=now()
        where id=any(mandatory_ids||satellite_ids) and cleanup_task_id is null;
      get diagnostics claimed=row_count;
      if claimed<>cardinality(mandatory_ids)+cardinality(satellite_ids) then raise exception 'stale_group'; end if;
      update public.clusters set status='scheduled' where id=any(cluster_ids);
      update public.dispatch_plan_items set commit_disposition='included',committed_task_id=task.id
        where dispatch_plan_id=plan_id and group_key=anchor.group_key and is_selected
          and (item_type<>'bundled_report' or report_id=any(satellite_ids));
      result:=jsonb_build_object('status',case when cardinality(omitted_ids)>0 then 'partial_commit' else 'committed' end,
        'group_key',anchor.group_key,'task_id',task.id,'crew_id',crew.id,
        'report_ids',mandatory_ids||satellite_ids,'satellite_report_ids',satellite_ids,'omitted_satellite_ids',omitted_ids);
    exception when raise_exception then
      get stacked diagnostics reason=message_text;
      if reason not in ('crew_unavailable','crew_has_no_members','crew_timing_changed','unknown_load',
        'stale_anchor','anchor_membership_changed','crew_assignment_changed','crew_capacity_changed',
        'capacity_volume','capacity_weight','stale_group','dispatch_blocked') then raise; end if;
      result:=jsonb_build_object('status','skipped','group_key',anchor.group_key,'reason',reason);
    end;
    insert into public.dispatch_group_commits(dispatch_plan_id,group_key,result)
      values(plan_id,anchor.group_key,result);
    results:=results||jsonb_build_array(result);
  end loop;
  update public.dispatch_plans set status='approved' where id=plan_id;
  return jsonb_build_object('plan_id',plan_id,'results',results,'tasks',
    coalesce((select jsonb_agg(to_jsonb(t)) from public.cleanup_tasks t where t.source_plan_id=plan_id),'[]'::jsonb));
end; $$;


create or replace function public.mixed_planning_snapshot()
returns jsonb language sql stable security invoker set search_path='' as $$
with anchors as (
  select c.id, c.priority_score, c.estimated_effort_minutes, c.recommended_task_type,
    c.created_at, extensions.st_y(c.center) as lat, extensions.st_x(c.center) as lng,
    (select case when count(*)=count(w.estimated_volume_m3) then sum(w.estimated_volume_m3) end from public.reports r left join public.work_time_configuration w on w.report_type=r.issue_type::text
      where r.cluster_id=c.id and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')) as estimated_volume_m3,
    (select case when count(*)=count(w.estimated_weight_kg) then sum(w.estimated_weight_kg) end from public.reports r left join public.work_time_configuration w on w.report_type=r.issue_type::text
      where r.cluster_id=c.id and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')) as estimated_weight_kg,
    array(select r.id from public.reports r where r.cluster_id=c.id
      and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')
      order by r.id) as report_ids
  from public.clusters c
  where c.status::text in ('new','unresolved','prioritized','queued','monitoring')
    and not exists(select 1 from public.dispatch_access_blocks b where b.cluster_id=c.id and b.cleared_at is null)
    and not exists(select 1 from public.reports r join public.dispatch_access_blocks b on b.report_id=r.id
      where r.cluster_id=c.id and b.cleared_at is null)
  order by c.priority_score desc nulls last,c.id limit 200
),
satellites as (
  select r.id, r.issue_type::text, r.lifecycle_state::text, r.severity_score, r.urgency_score,
    r.created_at, r.sla_started_at, r.deadline_at,
    extensions.st_y(r.location::extensions.geometry) as lat,
    extensions.st_x(r.location::extensions.geometry) as lng,
    w.work_time_minutes, w.estimated_volume_m3, w.estimated_weight_kg,
    exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null) as blocked
  from public.reports r left join public.work_time_configuration w on w.report_type=r.issue_type::text
  where r.status::text='unresolved' and r.cluster_id is null and r.cleanup_task_id is null
    and r.lifecycle_state in ('maturing','sla_breached') and r.location is not null
  order by r.deadline_at nulls last,r.id limit 200
)
select jsonb_build_object(
  'anchors',coalesce((select jsonb_agg(to_jsonb(a)) from anchors a where cardinality(a.report_ids)>0),'[]'::jsonb),
  'satellites',coalesce((select jsonb_agg(to_jsonb(s)) from satellites s),'[]'::jsonb)
);
$$;


-- A changed OUT signature requires dropping and recreating the function.
drop function public.dbscan_reports(double precision,integer);

create or replace function public.dbscan_reports(p_eps double precision,p_minpoints integer)
returns table(id uuid,issue_type text,location extensions.geometry,cluster_id integer)
language plpgsql security invoker set search_path='' as $$
begin
  if p_eps<=0 or p_eps>10000 or p_minpoints<2 or p_minpoints>100 then raise exception 'Invalid clustering parameters'; end if;
  return query select r.id,r.issue_type::text,r.location::extensions.geometry,
    extensions.st_clusterdbscan(extensions.st_transform(r.location::extensions.geometry,32651),eps:=p_eps,minpoints:=p_minpoints) over()
    from public.reports r where r.status::text='unresolved' and r.cluster_id is null and r.cleanup_task_id is null
      and r.lifecycle_state='fresh'
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null);
end; $$;


-- Remove unused detector and outlier clustering procedures.
drop function public.detect_sla_outliers();
drop function public.create_outlier_clusters();

drop trigger trigger_check_task_outlier on public.cleanup_tasks;
drop trigger trigger_check_cluster_outlier on public.clusters;
drop function public.check_task_outlier_consistency();
drop function public.check_cluster_outlier_consistency();

drop index public.idx_cleanup_tasks_is_outlier;
drop index public.idx_reports_is_outlier;
drop index public.idx_reports_sla_detection;
drop index public.idx_reports_outlier_clustering;
drop index public.idx_clusters_is_outlier;

alter table public.reports drop column is_outlier;
alter table public.clusters drop column is_outlier;
alter table public.cleanup_tasks drop column is_outlier;


create view public.reports_view with (security_invoker=true) as
select id,user_id,title,description,issue_type,location,validation_status,status,
  cluster_id,created_at,updated_at,notes,before_photo_url,after_photo_url,
  on_private_property,property_owner_consent_status,stage,satisfaction_rating,
  lgu_resolved_at,citizen_closed_at,is_overdue,severity_score,urgency_score,
  ra9003_category,ml_predicted_class,ml_confidence,ml_probabilities,
  deadline_at,fc_version,lifecycle_state,breached_at
from public.reports;

revoke all on public.reports_view from public,anon,authenticated;
grant select on public.reports_view to anon,authenticated;
grant all on public.reports_view to service_role;
revoke all on function public.dbscan_reports(double precision,integer) from public,anon,authenticated;
grant execute on function public.dbscan_reports(double precision,integer) to service_role;
commit;
