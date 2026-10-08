begin;
alter table public.dispatch_plans add column routing_token uuid, add column routing_lease_until timestamptz;

create function public.begin_plan_routing(plan_id uuid, actor uuid) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare plan public.dispatch_plans; token uuid;
begin
  perform workflow_private.require_desk_actor(actor);
  select * into plan from public.dispatch_plans where id=plan_id for update;
  if not found or plan.status::text<>'approved' then raise exception 'Committed plan required'; end if;
  if plan.optimization_run_id is not null then return jsonb_build_object('run_id',plan.optimization_run_id); end if;
  if plan.routing_lease_until>now() then return jsonb_build_object('running',true); end if;
  if plan.routing_attempts>=3 then return jsonb_build_object('exhausted',true); end if;
  token:=gen_random_uuid();
  update public.dispatch_plans set routing_token=token,routing_lease_until=now()+interval '90 seconds',routing_attempts=routing_attempts+1 where id=plan_id;
  return jsonb_build_object('token',token);
end; $$;

create function public.finish_plan_routing(plan_id uuid, actor uuid, token uuid, failure text) returns void
language plpgsql security invoker set search_path='' as $$
begin
  perform workflow_private.require_desk_actor(actor);
  update public.dispatch_plans set routing_token=null,routing_lease_until=null where id=plan_id and routing_token=token;
  if found and failure is not null then
    insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
      values('PLAN_ROUTING_FAILED','PLAN',plan_id::text,actor::text,jsonb_build_object('reason',left(failure,1000)));
  end if;
end; $$;

create function public.task_coordinates(task_ids uuid[]) returns jsonb
language sql security invoker set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'lat',extensions.st_y(coalesce(t.location::extensions.geometry,c.center)),
    'lng',extensions.st_x(coalesce(t.location::extensions.geometry,c.center)))),'[]'::jsonb)
  from public.cleanup_tasks t left join public.clusters c on c.id=t.cluster_id where t.id=any(task_ids);
$$;

create function public.publish_dispatch_routes(plan_id uuid, actor uuid, token uuid, routes jsonb, depot jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare plan public.dispatch_plans; crew public.field_crews; run public.optimization_runs; crew_route public.crew_routes;
  route jsonb; waypoint jsonb; ids uuid[]; all_ids uuid[]; expected_ids uuid[]; members uuid[];
  work_minutes numeric; travel_minutes numeric; shift_minutes numeric; busy numeric; busy_count integer; task_index integer;
  current_task public.cleanup_tasks; latitude numeric; longitude numeric;
begin
  perform workflow_private.require_desk_actor(actor);
  select * into plan from public.dispatch_plans where id=plan_id for update;
  if not found then raise exception 'Plan not found'; end if;
  if plan.optimization_run_id is not null then
    return jsonb_build_object('run_id',plan.optimization_run_id,'alreadyPublished',true);
  end if;
  if plan.routing_token is distinct from token or token is null or plan.routing_lease_until<now() then raise exception 'Routing lease expired'; end if;
  if jsonb_typeof(routes) is distinct from 'array' then raise exception 'Routes must be an array'; end if;
  perform id from public.cleanup_tasks where source_plan_id=plan_id order by id for update;
  perform r.id from public.reports r join public.cleanup_tasks t on t.id=r.cleanup_task_id where t.source_plan_id=plan_id order by r.id for update of r;
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into expected_ids from public.cleanup_tasks where source_plan_id=plan_id;
  select coalesce(array_agg(v::uuid order by v::uuid),'{}'::uuid[]) into all_ids from jsonb_array_elements(routes) r
    cross join lateral jsonb_array_elements_text(r->'task_ids') v;
  if expected_ids<>all_ids then raise exception 'Routes must contain every committed task exactly once'; end if;
  if cardinality(expected_ids)=0 then return jsonb_build_object('run_id',null,'alreadyPublished',false); end if;
  if exists(select 1 from public.cleanup_tasks t where source_plan_id=plan_id and
    (t.route_status<>'needs_replan' or t.status::text not in ('created','pending') or t.assigned_at is not null or t.routing_deadline_at<=now())) then
    raise exception 'Committed task is unavailable or expired';
  end if;
  if exists(select 1 from public.cleanup_tasks t cross join lateral unnest(t.report_ids) rid
    left join public.reports r on r.id=rid where t.source_plan_id=plan_id
      and (r.id is null or r.cleanup_task_id is distinct from t.id or r.lifecycle_state='closed')) then
    raise exception 'Report changed before route publication';
  end if;
  if (select count(*) from jsonb_array_elements(routes))<>(select count(distinct r->>'crew_id') from jsonb_array_elements(routes) r) then
    raise exception 'Duplicate route for crew';
  end if;
  latitude:=(depot->>'latitude')::numeric; longitude:=(depot->>'longitude')::numeric;
  if latitude is null or longitude is null or latitude not between -90 and 90 or longitude not between -180 and 180 then raise exception 'Invalid depot'; end if;
  insert into public.optimization_runs(triggered_by,status,approved_by,approved_at,criteria,num_tasks_optimized,num_crews)
    values(actor,'approved',actor,now(),jsonb_build_object('mode',plan.mode,'source_plan_id',plan.id),cardinality(expected_ids),jsonb_array_length(routes)) returning * into run;
  for route in select r from jsonb_array_elements(routes) r order by r->>'crew_id' loop
    select * into crew from public.field_crews where id=(route->>'crew_id')::uuid for update;
    if not found or crew.availability_status::text<>'available' or (plan.mode='standard' and not crew.supports_standard)
      or (plan.mode='sweeper' and not crew.supports_sweeper) then raise exception 'Crew capability changed'; end if;
    members:=array(select distinct x from unnest(coalesce(crew.member_profile_ids,'{}'::uuid[])||array_remove(array[crew.team_lead_profile_id],null)) x order by x);
    if cardinality(members)=0 then raise exception 'Crew has no members'; end if;
    if crew.speed_factor is distinct from (route->>'speed_factor')::numeric or crew.service_time_factor is distinct from (route->>'service_time_factor')::numeric then
      raise exception 'Fleet timing factors changed';
    end if;
    if exists(select 1 from public.dispatch_plan_items where dispatch_plan_id=plan_id and planned_crew_id=crew.id and is_selected
      and ((crew_snapshot->>'speed_factor')::numeric is distinct from crew.speed_factor
        or (crew_snapshot->>'service_time_factor')::numeric is distinct from crew.service_time_factor)) then raise exception 'Fleet timing factors changed since commit'; end if;
    select array_agg(id::uuid order by ord) into ids from jsonb_array_elements_text(route->'task_ids') with ordinality v(id,ord);
    if jsonb_typeof(route->'waypoints') is distinct from 'array' or jsonb_array_length(route->'waypoints')<>cardinality(ids)+2
      or route->'waypoints'->0->>'waypoint_type' is distinct from 'depot_start'
      or route->'waypoints'->-1->>'waypoint_type' is distinct from 'depot_end' then raise exception 'Complete depot-to-depot route required'; end if;
    if (select array_agg((w->>'cleanup_task_id')::uuid order by ord) from jsonb_array_elements(route->'waypoints') with ordinality x(w,ord)
      where w->>'waypoint_type'='task') is distinct from ids then raise exception 'Waypoint order differs from task order'; end if;
    if exists(select 1 from jsonb_array_elements(route->'waypoints') with ordinality x(w,ord) where
      (w->>'sequence_order')::integer is distinct from ord-1) then raise exception 'Invalid waypoint sequence'; end if;
    if exists(select 1 from public.cleanup_tasks where id=any(ids) and assigned_field_crew_id<>crew.id) then raise exception 'Wrong crew for task'; end if;
    select coalesce(sum(estimated_work_minutes),0) into work_minutes from public.cleanup_tasks where id=any(ids);
    select coalesce(sum((w->>'estimated_time_from_previous_min')::numeric),0) into travel_minutes from jsonb_array_elements(route->'waypoints') w;
    if work_minutes<0 or travel_minutes<0 then raise exception 'Invalid route durations'; end if;
    shift_minutes:=extract(epoch from(crew.shift_end-crew.shift_start))/60;
    if shift_minutes<0 then shift_minutes:=shift_minutes+1440; end if;
    select coalesce(sum(coalesce(estimated_duration_min,60)),0),count(*) into busy,busy_count from public.cleanup_tasks
      where status::text not in ('completed','cancelled') and not(id=any(ids))
        and (assigned_field_crew_id=crew.id or coalesce(assigned_crew_ids,'{}'::uuid[])&&members);
    if busy+work_minutes+travel_minutes>greatest(0,(shift_minutes-coalesce((plan.settings_snapshot->>'break_duration_min')::numeric,60)
      +coalesce((plan.settings_snapshot->>'overtime_tolerance_min')::numeric,15))*coalesce((plan.settings_snapshot->>'capacity_utilization')::numeric,1))
      or busy_count+cardinality(ids)>least(coalesce(crew.max_tasks_per_shift,10),coalesce((plan.settings_snapshot->>'max_tasks_per_shift')::integer,15)) then
      raise exception 'Published route exceeds crew capacity';
    end if;
    insert into public.crew_routes(optimization_run_id,crew_id,start_depot,end_depot,total_distance_meters,total_duration_min,task_count,traffic_snapshot)
      values(run.id,crew.id,extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)::extensions.geography,
        extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)::extensions.geography,(route->>'totalDistance')::numeric,
        work_minutes+travel_minutes,cardinality(ids),jsonb_build_object('approximate',coalesce((route->>'approximate')::boolean,false))) returning * into crew_route;
    if (select count(distinct w->>'cleanup_task_id') from jsonb_array_elements(route->'waypoints') w where w->>'waypoint_type'='task')<>cardinality(ids)
      or exists(select 1 from jsonb_array_elements(route->'waypoints') w where w->>'waypoint_type'='task' and not((w->>'cleanup_task_id')::uuid=any(ids))) then
      raise exception 'Route waypoints do not match assigned tasks';
    end if;
    for waypoint in select value from jsonb_array_elements(route->'waypoints') loop
      if waypoint->>'latitude' is null or waypoint->>'longitude' is null or waypoint->>'estimated_time_from_previous_min' is null
        or waypoint->>'distance_from_previous_meters' is null
        or (waypoint->>'latitude')::numeric not between -90 and 90 or (waypoint->>'longitude')::numeric not between -180 and 180
        or (waypoint->>'estimated_time_from_previous_min')::numeric<0 or (waypoint->>'distance_from_previous_meters')::numeric<0 then
        raise exception 'Invalid waypoint';
      end if;
      insert into public.route_waypoints(crew_route_id,sequence_order,latitude,longitude,cleanup_task_id,waypoint_type,
        distance_from_previous_meters,estimated_time_from_previous_min,polyline)
      values(crew_route.id,(waypoint->>'sequence_order')::integer,(waypoint->>'latitude')::numeric,(waypoint->>'longitude')::numeric,
        (waypoint->>'cleanup_task_id')::uuid,(waypoint->>'waypoint_type')::public.route_waypoint_type,
        (waypoint->>'distance_from_previous_meters')::numeric,(waypoint->>'estimated_time_from_previous_min')::numeric,waypoint->'polyline');
    end loop;
    for task_index in 1..cardinality(ids) loop
      select * into current_task from public.cleanup_tasks where id=ids[task_index];
      update public.cleanup_tasks set crew_route_id=crew_route.id,sequence_in_route=task_index,assigned_crew_ids=members,
        assigned_at=now(),assigned_by=actor,last_assigned_at=now(),route_status='ready',fc_version=fc_version+1,
        estimated_duration_min=estimated_work_minutes+
          ceil((select (w->>'estimated_time_from_previous_min')::numeric from jsonb_array_elements(route->'waypoints') w where w->>'cleanup_task_id'=current_task.id::text))+
          case when task_index=cardinality(ids) then ceil((select coalesce(sum((w->>'estimated_time_from_previous_min')::numeric),0) from jsonb_array_elements(route->'waypoints') w where w->>'waypoint_type'='depot_end')) else 0 end
        where id=current_task.id;
    end loop;
  end loop;
  update public.dispatch_plans set optimization_run_id=run.id,routing_token=null,routing_lease_until=null where id=plan_id;
  insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
    values('DISPATCH_ROUTES_PUBLISHED','PLAN',plan_id::text,actor::text,jsonb_build_object('run_id',run.id,'tasks',expected_ids));
  return jsonb_build_object('run_id',run.id,'alreadyPublished',false);
end; $$;
revoke all on function public.begin_plan_routing(uuid,uuid),public.finish_plan_routing(uuid,uuid,uuid,text),public.task_coordinates(uuid[]),public.publish_dispatch_routes(uuid,uuid,uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.begin_plan_routing(uuid,uuid),public.finish_plan_routing(uuid,uuid,uuid,text),public.task_coordinates(uuid[]),public.publish_dispatch_routes(uuid,uuid,uuid,jsonb,jsonb) to service_role;
commit;
