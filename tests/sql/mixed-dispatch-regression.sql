create function pg_temp.assert_true(value boolean, message text) returns void language plpgsql as $$
begin if value is distinct from true then raise exception 'Mixed assertion failed: %',message; end if; end; $$;

insert into public.profiles(id,role,full_name) values
 ('00000000-0000-0000-0000-000000000005','field_crew','Mixed crew member');
insert into public.field_crews(id,name,member_profile_ids,shift_start,shift_end,max_tasks_per_shift,
  supports_standard,supports_sweeper,max_volume_m3,max_weight_kg,starting_volume_m3,starting_weight_kg,load_measured_at)
values('00000000-0000-0000-0000-000000000030','Mixed crew',
  array['00000000-0000-0000-0000-000000000005'::uuid],
  '08:00','17:00',10,true,true,5,1000,1,100,now());

insert into public.sweeper_configuration(parameter_name,parameter_value)
values('high_severity_maturation_hours','{"hours":0.00001}')
on conflict(parameter_name) do update set parameter_value=excluded.parameter_value;

insert into public.clusters(id,center,report_count,severity,issue_type,is_outlier)
values('00000000-0000-0000-0000-000000000200',
  extensions.st_setsrid(extensions.st_makepoint(121,14),4326),1,'low','waste',false);
insert into public.reports(id,cluster_id,location)
values('00000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000200',
  extensions.st_setsrid(extensions.st_makepoint(121,14),4326)::extensions.geography);
insert into public.reports(id,location,severity_score)
values('00000000-0000-0000-0000-000000000202',
  extensions.st_setsrid(extensions.st_makepoint(121.001,14.001),4326)::extensions.geography,90);
select pg_sleep(0.1);
select public.advance_report_lifecycle();

do $$
declare actor uuid:='00000000-0000-0000-0000-000000000001';
  crew uuid:='00000000-0000-0000-0000-000000000030';
  cluster_id uuid:='00000000-0000-0000-0000-000000000200';
  anchor_report uuid:='00000000-0000-0000-0000-000000000201';
  satellite_report uuid:='00000000-0000-0000-0000-000000000202';
  job jsonb; lease jsonb; plan jsonb; committed jsonb; task_id uuid; route_lease jsonb; published jsonb;
  configuration jsonb:='{"mode":"mixed","break_duration_min":60,"overtime_tolerance_min":15,"capacity_utilization":1,"max_tasks_per_shift":15,"mixed_max_detour_minutes":30,"depot":{"lat":14,"lng":121}}';
  proposal jsonb:='{"routes":[],"node_ids":[],"travel_time_matrix_min":[]}';
  items jsonb; routes jsonb;
begin
  perform pg_temp.assert_true((select lifecycle_state='maturing' from public.reports where id=satellite_report),
    'high-severity satellite matured');
  job:=public.enqueue_plan_generation(actor,'mixed',configuration,'partial-anchor-case');
  lease:=public.claim_plan_generation(gen_random_uuid());
  perform pg_temp.assert_true(lease->>'id'=job->>'jobId','worker claimed the queued job');
  items:=jsonb_build_array(
    jsonb_build_object('item_type','cluster','cluster_id',cluster_id,'cluster_ids',array[cluster_id],
      'report_ids',array[anchor_report],'group_key','cluster:'||cluster_id,'planned_crew_id',crew,
      'is_selected',true,'estimated_work_minutes',30,'estimated_duration_minutes',45,
      'priority_score',80,'estimated_volume_m3',0.3,'estimated_weight_kg',30,
      'crew_snapshot',jsonb_build_object('speed_factor',1,'service_time_factor',1)),
    jsonb_build_object('item_type','bundled_report','report_id',satellite_report,
      'anchor_cluster_id',cluster_id,'report_ids',array[satellite_report],
      'group_key','cluster:'||cluster_id,'planned_crew_id',crew,'is_selected',true,
      'estimated_work_minutes',10,'estimated_duration_minutes',15,'priority_score',70,
      'bundle_order',1,'detour_minutes',5,'estimated_volume_m3',0.1,'estimated_weight_kg',10,
      'crew_snapshot',jsonb_build_object('speed_factor',1,'service_time_factor',1)));
  plan:=public.save_mixed_dispatch_draft(actor,(job->>'jobId')::uuid,(lease->>'worker_token')::uuid,
    configuration,items,proposal,'{"availableCrews":1,"totalMinutes":480}','[]','{}');
  begin
    perform public.commit_mixed_dispatch_plan((plan->>'id')::uuid,actor);
    raise exception 'Incomplete job was allowed to commit';
  exception when others then
    if sqlerrm='Incomplete job was allowed to commit' then raise; end if;
  end;
  perform public.finish_plan_generation((job->>'jobId')::uuid,(lease->>'worker_token')::uuid,
    (plan->>'id')::uuid,null,'{}');
  update public.reports set status='resolved' where id=satellite_report;
  committed:=public.commit_mixed_dispatch_plan((plan->>'id')::uuid,actor);
  task_id:=(committed->'results'->0->>'task_id')::uuid;
  perform pg_temp.assert_true(committed->'results'->0->>'status'='partial_commit','stale satellite gives a partial commit');
  perform pg_temp.assert_true(task_id is not null and
    (select report_ids=array[anchor_report] and satellite_report_ids='{}'::uuid[]
      from public.cleanup_tasks where id=task_id),'anchor alone is claimed');
  perform pg_temp.assert_true((select cleanup_task_id is null from public.reports where id=satellite_report),
    'closed satellite was not re-claimed');
  perform pg_temp.assert_true((select commit_disposition='omitted' from public.dispatch_plan_items
    where dispatch_plan_id=(plan->>'id')::uuid and report_id=satellite_report),
    'stale satellite omission is recorded');
  route_lease:=public.begin_plan_routing((plan->>'id')::uuid,actor);
  routes:=jsonb_build_array(jsonb_build_object('crew_id',crew,'task_ids',array[task_id],
    'speed_factor',1,'service_time_factor',1,'totalDistance',200,'approximate',true,
    'waypoints',jsonb_build_array(
      jsonb_build_object('sequence_order',0,'latitude',14,'longitude',121,'waypoint_type','depot_start',
        'distance_from_previous_meters',0,'estimated_time_from_previous_min',0),
      jsonb_build_object('sequence_order',1,'latitude',14,'longitude',121,'waypoint_type','task',
        'cleanup_task_id',task_id,'distance_from_previous_meters',100,'estimated_time_from_previous_min',1),
      jsonb_build_object('sequence_order',2,'latitude',14,'longitude',121,'waypoint_type','depot_end',
        'distance_from_previous_meters',100,'estimated_time_from_previous_min',1))));
  published:=public.publish_mixed_dispatch_routes((plan->>'id')::uuid,actor,
    (route_lease->>'token')::uuid,routes,'{"latitude":14,"longitude":121}');
  perform pg_temp.assert_true(published->>'run_id' is not null,'partial anchor route published');
  perform pg_temp.assert_true((select route_status='ready' from public.cleanup_tasks where id=task_id),
    'anchor task became ready only after route publication');
  perform pg_temp.assert_true((select count(*)=0 from public.route_waypoints where report_id=satellite_report),
    'stale satellite has no route waypoint');
end $$;

insert into public.clusters(id,center,report_count,severity,issue_type,is_outlier)
values('00000000-0000-0000-0000-000000000203',
  extensions.st_setsrid(extensions.st_makepoint(121.01,14.01),4326),1,'low','waste',false);
insert into public.reports(id,cluster_id,location)
values('00000000-0000-0000-0000-000000000204',
  '00000000-0000-0000-0000-000000000203',
  extensions.st_setsrid(extensions.st_makepoint(121.01,14.01),4326)::extensions.geography);
insert into public.reports(id,location,severity_score)
values('00000000-0000-0000-0000-000000000205',
  extensions.st_setsrid(extensions.st_makepoint(121.011,14.011),4326)::extensions.geography,90);
select pg_sleep(0.1);
select public.advance_report_lifecycle();

do $$
declare actor uuid:='00000000-0000-0000-0000-000000000001';
  crew uuid:='00000000-0000-0000-0000-000000000030';
  cluster_id uuid:='00000000-0000-0000-0000-000000000203';
  anchor_report uuid:='00000000-0000-0000-0000-000000000204';
  satellite_report uuid:='00000000-0000-0000-0000-000000000205';
  configuration jsonb:='{"mode":"mixed","break_duration_min":60,"overtime_tolerance_min":15,"capacity_utilization":1,"max_tasks_per_shift":15,"mixed_max_detour_minutes":30,"depot":{"lat":14,"lng":121}}';
  job jsonb; lease jsonb; plan jsonb; committed jsonb; task_id uuid;
  route_lease jsonb; routes jsonb; published jsonb; items jsonb;
begin
  perform pg_temp.assert_true((select lifecycle_state='maturing' from public.reports where id=satellite_report),
    'retained satellite matured');
  job:=public.enqueue_plan_generation(actor,'mixed',configuration,'retained-satellite-case');
  lease:=public.claim_plan_generation(gen_random_uuid());
  items:=jsonb_build_array(
    jsonb_build_object('item_type','cluster','cluster_id',cluster_id,'cluster_ids',array[cluster_id],
      'report_ids',array[anchor_report],'group_key','cluster:'||cluster_id,'planned_crew_id',crew,
      'is_selected',true,'estimated_work_minutes',30,'estimated_duration_minutes',45,
      'priority_score',80,'estimated_volume_m3',0.3,'estimated_weight_kg',30,
      'crew_snapshot',jsonb_build_object('speed_factor',1,'service_time_factor',1)),
    jsonb_build_object('item_type','bundled_report','report_id',satellite_report,
      'anchor_cluster_id',cluster_id,'report_ids',array[satellite_report],
      'group_key','cluster:'||cluster_id,'planned_crew_id',crew,'is_selected',true,
      'estimated_work_minutes',10,'estimated_duration_minutes',15,'priority_score',70,
      'bundle_order',1,'detour_minutes',5,'estimated_volume_m3',0.1,'estimated_weight_kg',10,
      'crew_snapshot',jsonb_build_object('speed_factor',1,'service_time_factor',1)));
  plan:=public.save_mixed_dispatch_draft(actor,(job->>'jobId')::uuid,(lease->>'worker_token')::uuid,
    configuration,items,'{"routes":[]}','{"availableCrews":1,"totalMinutes":480}','[]','{}');
  perform public.finish_plan_generation((job->>'jobId')::uuid,(lease->>'worker_token')::uuid,
    (plan->>'id')::uuid,null,'{}');
  committed:=public.commit_mixed_dispatch_plan((plan->>'id')::uuid,actor);
  task_id:=(committed->'results'->0->>'task_id')::uuid;
  perform pg_temp.assert_true(committed->'results'->0->>'status'='committed','retained bundle committed');
  perform pg_temp.assert_true((select satellite_report_ids=array[satellite_report]
    from public.cleanup_tasks where id=task_id),'satellite claim stored on anchor task');
  route_lease:=public.begin_plan_routing((plan->>'id')::uuid,actor);
  routes:=jsonb_build_array(jsonb_build_object('crew_id',crew,'task_ids',array[task_id],
    'speed_factor',1,'service_time_factor',1,'totalDistance',400,'approximate',true,
    'waypoints',jsonb_build_array(
      jsonb_build_object('sequence_order',0,'latitude',14,'longitude',121,'waypoint_type','depot_start',
        'distance_from_previous_meters',0,'estimated_time_from_previous_min',0),
      jsonb_build_object('sequence_order',1,'latitude',14.01,'longitude',121.01,'waypoint_type','task',
        'cleanup_task_id',task_id,'distance_from_previous_meters',100,'estimated_time_from_previous_min',1),
      jsonb_build_object('sequence_order',2,'latitude',14.011,'longitude',121.011,
        'waypoint_type','bundled_report','cleanup_task_id',task_id,'report_id',satellite_report,
        'distance_from_previous_meters',100,'estimated_time_from_previous_min',1),
      jsonb_build_object('sequence_order',3,'latitude',14,'longitude',121,'waypoint_type','depot_end',
        'distance_from_previous_meters',200,'estimated_time_from_previous_min',1))));
  published:=public.publish_mixed_dispatch_routes((plan->>'id')::uuid,actor,
    (route_lease->>'token')::uuid,routes,'{"latitude":14,"longitude":121}');
  perform pg_temp.assert_true(published->>'run_id' is not null,'retained bundle route published');
  perform pg_temp.assert_true((select count(*)=1 from public.route_waypoints
    where cleanup_task_id=task_id and report_id=satellite_report and waypoint_type='bundled_report'),
    'satellite waypoint remains attached to anchor task');
end $$;
