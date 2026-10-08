begin;

create function public.publish_mixed_dispatch_routes(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare plan public.dispatch_plans; crew public.field_crews; run public.optimization_runs;
  crew_route public.crew_routes; route jsonb; waypoint jsonb; task public.cleanup_tasks;
  expected_ids uuid[]; route_ids uuid[]; ids uuid[]; expected_reports uuid[]; route_reports uuid[];
  task_satellites uuid[]; waypoint_satellites uuid[]; latitude numeric; longitude numeric;
  work_minutes numeric; travel_minutes numeric; shift_minutes numeric; busy_minutes numeric;
  busy_count integer; busy_volume numeric; busy_weight numeric; route_volume numeric; route_weight numeric;
  members uuid[]; task_index integer;
begin
  perform workflow_private.require_desk_actor(actor);
  select * into plan from public.dispatch_plans where id=plan_id for update;
  if not found or plan.mode<>'mixed' or plan.status::text<>'approved' then raise exception 'Approved Mixed plan required'; end if;
  if plan.optimization_run_id is not null then return jsonb_build_object('run_id',plan.optimization_run_id,'alreadyPublished',true); end if;
  if token is null or plan.routing_token is distinct from token or plan.routing_lease_until<now() then
    raise exception 'Routing lease expired'; end if;
  if jsonb_typeof(routes) is distinct from 'array' then raise exception 'Routes array required'; end if;
  perform id from public.cleanup_tasks where source_plan_id=plan_id order by id for update;
  perform r.id from public.reports r join public.cleanup_tasks t on t.id=r.cleanup_task_id
    where t.source_plan_id=plan_id order by r.id for update of r;
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into expected_ids
    from public.cleanup_tasks where source_plan_id=plan_id;
  select coalesce(array_agg(v::uuid order by v::uuid),'{}'::uuid[]) into route_ids
    from jsonb_array_elements(routes) r cross join lateral jsonb_array_elements_text(r->'task_ids') v;
  if expected_ids<>route_ids then raise exception 'Route task membership differs from commit'; end if;
  select coalesce(array_agg(rid order by rid),'{}'::uuid[]) into expected_reports
    from public.cleanup_tasks t cross join lateral unnest(t.satellite_report_ids) rid
    where t.source_plan_id=plan_id;
  select coalesce(array_agg((w->>'report_id')::uuid order by (w->>'report_id')::uuid),'{}'::uuid[])
    into route_reports from jsonb_array_elements(routes) r
      cross join lateral jsonb_array_elements(r->'waypoints') w
    where w->>'waypoint_type'='bundled_report';
  if expected_reports<>route_reports then raise exception 'Route satellite membership differs from commit'; end if;
  if exists(select 1 from public.cleanup_tasks t where t.source_plan_id=plan_id and
    (t.route_status<>'needs_replan' or t.status::text not in ('created','pending')
      or t.assigned_at is not null or t.routing_deadline_at<=now())) then
    raise exception 'Committed task unavailable or expired'; end if;
  if exists(select 1 from public.cleanup_tasks t cross join lateral unnest(t.report_ids) rid
    left join public.reports r on r.id=rid where t.source_plan_id=plan_id
      and (r.id is null or r.cleanup_task_id is distinct from t.id or r.lifecycle_state='closed')) then
    raise exception 'Claimed report changed before publication'; end if;
  latitude:=(depot->>'latitude')::numeric; longitude:=(depot->>'longitude')::numeric;
  if latitude is null or longitude is null or latitude not between -90 and 90 or longitude not between -180 and 180 then
    raise exception 'Invalid depot'; end if;
  if cardinality(expected_ids)=0 then
    update public.dispatch_plans set routing_token=null,routing_lease_until=null where id=plan_id;
    return jsonb_build_object('run_id',null,'alreadyPublished',false);
  end if;
  insert into public.optimization_runs(triggered_by,status,approved_by,approved_at,criteria,num_tasks_optimized,num_crews)
    values(actor,'approved',actor,now(),jsonb_build_object('mode','mixed','source_plan_id',plan_id),
      cardinality(expected_ids),jsonb_array_length(routes)) returning * into run;
  for route in select value from jsonb_array_elements(routes) order by value->>'crew_id' loop
    select * into crew from public.field_crews where id=(route->>'crew_id')::uuid for update;
    if not found or crew.availability_status::text<>'available' then raise exception 'Crew unavailable'; end if;
    if crew.speed_factor is distinct from (route->>'speed_factor')::numeric
      or crew.service_time_factor is distinct from (route->>'service_time_factor')::numeric then
      raise exception 'Fleet timing factors changed'; end if;
    if exists(select 1 from public.dispatch_plan_items i where i.dispatch_plan_id=plan_id
      and i.is_selected and i.planned_crew_id=crew.id
      and ((i.crew_snapshot->>'speed_factor')::numeric is distinct from crew.speed_factor
        or (i.crew_snapshot->>'service_time_factor')::numeric is distinct from crew.service_time_factor)) then
      raise exception 'Fleet timing factors changed since planning'; end if;
    members:=array(select distinct x from unnest(coalesce(crew.member_profile_ids,'{}'::uuid[])
      ||array_remove(array[crew.team_lead_profile_id],null)) x order by x);
    if cardinality(members)=0 then raise exception 'Crew has no members'; end if;
    select array_agg(value::uuid order by ord) into ids
      from jsonb_array_elements_text(route->'task_ids') with ordinality x(value,ord);
    if cardinality(ids)=0 then raise exception 'Empty route'; end if;
    if exists(select 1 from public.cleanup_tasks t where t.id=any(ids)
      and t.assigned_field_crew_id is distinct from crew.id) then raise exception 'Wrong crew for task'; end if;
    if exists(select 1 from public.cleanup_tasks t where t.id=any(ids)
      and ((t.task_type::text='Mixed' and not crew.supports_standard)
        or (t.task_type::text='Sweeper' and not crew.supports_sweeper))) then
      raise exception 'Crew capability changed'; end if;
    if jsonb_typeof(route->'waypoints') is distinct from 'array'
      or route->'waypoints'->0->>'waypoint_type' is distinct from 'depot_start'
      or route->'waypoints'->-1->>'waypoint_type' is distinct from 'depot_end' then
      raise exception 'Complete route required'; end if;
    if (select array_agg((w->>'cleanup_task_id')::uuid order by ord)
      from jsonb_array_elements(route->'waypoints') with ordinality x(w,ord)
      where w->>'waypoint_type'='task') is distinct from ids then
      raise exception 'Task waypoint order differs from saved route'; end if;
    if exists(select 1 from jsonb_array_elements(route->'waypoints') with ordinality x(w,ord)
      where (w->>'sequence_order')::integer is distinct from ord-1) then
      raise exception 'Invalid waypoint sequence'; end if;
    for task in select * from public.cleanup_tasks where id=any(ids) loop
      select coalesce(array_agg((w->>'report_id')::uuid order by ord),'{}'::uuid[])
        into waypoint_satellites from jsonb_array_elements(route->'waypoints') with ordinality x(w,ord)
        where w->>'waypoint_type'='bundled_report' and (w->>'cleanup_task_id')::uuid=task.id;
      task_satellites:=coalesce(task.satellite_report_ids,'{}'::uuid[]);
      if waypoint_satellites<>task_satellites then raise exception 'Satellite waypoint order differs from committed task'; end if;
    end loop;
    select coalesce(sum(estimated_work_minutes),0),coalesce(sum(estimated_volume_m3),0),
      coalesce(sum(estimated_weight_kg),0) into work_minutes,route_volume,route_weight
      from public.cleanup_tasks where id=any(ids);
    select coalesce(sum((w->>'estimated_time_from_previous_min')::numeric),0)
      into travel_minutes from jsonb_array_elements(route->'waypoints') w;
    if travel_minutes<0 then raise exception 'Invalid route travel'; end if;
    shift_minutes:=extract(epoch from(crew.shift_end-crew.shift_start))/60;
    if shift_minutes<0 then shift_minutes:=shift_minutes+1440; end if;
    select coalesce(sum(coalesce(estimated_duration_min,60)),0),count(*),
      coalesce(sum(estimated_volume_m3),0),coalesce(sum(estimated_weight_kg),0)
      into busy_minutes,busy_count,busy_volume,busy_weight from public.cleanup_tasks
      where status::text not in ('completed','cancelled') and not(id=any(ids))
        and assigned_field_crew_id=crew.id;
    if crew.max_volume_m3 is null or crew.max_weight_kg is null
      or crew.starting_volume_m3 is null or crew.starting_weight_kg is null
      or exists(select 1 from public.cleanup_tasks t where t.assigned_field_crew_id=crew.id
        and t.status::text not in ('completed','cancelled') and
        (t.estimated_volume_m3 is null or t.estimated_weight_kg is null)) then
      raise exception 'Physical load estimate unavailable'; end if;
    if busy_minutes+work_minutes+travel_minutes>greatest(0,(shift_minutes-
      coalesce((plan.settings_snapshot->>'break_duration_min')::numeric,60)+
      coalesce((plan.settings_snapshot->>'overtime_tolerance_min')::numeric,15))
      *coalesce((plan.settings_snapshot->>'capacity_utilization')::numeric,1))
      or busy_count+cardinality(ids)>least(coalesce(crew.max_tasks_per_shift,10),
        coalesce((plan.settings_snapshot->>'max_tasks_per_shift')::integer,15)) then
      raise exception 'Published route exceeds crew time capacity'; end if;
    if crew.starting_volume_m3+busy_volume+route_volume>crew.max_volume_m3
      or crew.starting_weight_kg+busy_weight+route_weight>crew.max_weight_kg then
      raise exception 'Published route exceeds physical capacity'; end if;
    insert into public.crew_routes(optimization_run_id,crew_id,start_depot,end_depot,
      total_distance_meters,total_duration_min,task_count,traffic_snapshot)
      values(run.id,crew.id,extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)::extensions.geography,
        extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)::extensions.geography,
        (route->>'totalDistance')::numeric,work_minutes+travel_minutes,cardinality(ids),
        jsonb_build_object('approximate',coalesce((route->>'approximate')::boolean,true))) returning * into crew_route;
    for waypoint in select value from jsonb_array_elements(route->'waypoints') loop
      if (waypoint->>'latitude')::numeric not between -90 and 90
        or (waypoint->>'longitude')::numeric not between -180 and 180
        or (waypoint->>'estimated_time_from_previous_min')::numeric<0
        or (waypoint->>'distance_from_previous_meters')::numeric<0 then raise exception 'Invalid waypoint'; end if;
      insert into public.route_waypoints(crew_route_id,sequence_order,latitude,longitude,
        cleanup_task_id,report_id,waypoint_type,distance_from_previous_meters,
        estimated_time_from_previous_min,polyline)
      values(crew_route.id,(waypoint->>'sequence_order')::integer,(waypoint->>'latitude')::numeric,
        (waypoint->>'longitude')::numeric,(waypoint->>'cleanup_task_id')::uuid,
        (waypoint->>'report_id')::uuid,(waypoint->>'waypoint_type')::public.route_waypoint_type,
        (waypoint->>'distance_from_previous_meters')::numeric,
        (waypoint->>'estimated_time_from_previous_min')::numeric,waypoint->'polyline');
    end loop;
    for task_index in 1..cardinality(ids) loop
      update public.cleanup_tasks set crew_route_id=crew_route.id,sequence_in_route=task_index,
        assigned_crew_ids=members,assigned_at=now(),assigned_by=actor,last_assigned_at=now(),
        route_status='ready',route_revision=route_revision+1,fc_version=fc_version+1
        where id=ids[task_index];
    end loop;
  end loop;
  update public.dispatch_plans set optimization_run_id=run.id,routing_token=null,routing_lease_until=null
    where id=plan_id;
  return jsonb_build_object('run_id',run.id,'alreadyPublished',false);
end; $$;

revoke all on function public.publish_mixed_dispatch_routes(uuid,uuid,uuid,jsonb,jsonb)
  from public,anon,authenticated;
grant execute on function public.publish_mixed_dispatch_routes(uuid,uuid,uuid,jsonb,jsonb)
  to service_role;

commit;
