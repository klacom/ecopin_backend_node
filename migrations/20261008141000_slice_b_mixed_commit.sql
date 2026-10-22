begin;

create function public.commit_mixed_dispatch_plan(plan_id uuid, actor uuid)
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
        scheduled_date,location,is_outlier,priority_score,estimated_volume_m3,estimated_weight_kg)
      values(anchor.cluster_id,cluster_ids,mandatory_ids||satellite_ids,mandatory_ids||satellite_ids,satellite_ids,
        case when anchor.item_type='cluster' then 'Mixed cluster cleanup' else 'Sweeper pickup' end,
        'pending',case when anchor.item_type='cluster' then 'Mixed'::public.cleanup_task_type else 'Sweeper'::public.cleanup_task_type end,
        ceil(group_minutes),anchor.estimated_work_minutes+coalesce((select sum(i.estimated_work_minutes)
          from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id and i.group_key=anchor.group_key
            and i.report_id=any(satellite_ids)),0),actor,plan_id,anchor.group_key,crew.id,'mixed',
        'needs_replan',now()+interval '30 minutes',plan.planned_date,
        (select location from public.reports where id=mandatory_ids[1]),anchor.item_type='report',
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

revoke all on function public.commit_mixed_dispatch_plan(uuid,uuid) from public,anon,authenticated;
grant execute on function public.commit_mixed_dispatch_plan(uuid,uuid) to service_role;

commit;
