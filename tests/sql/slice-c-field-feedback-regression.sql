do $$ <<regression>>
declare
  actor_id uuid := '00000000-0000-0000-0000-000000000002';
  crew_id uuid := '00000000-0000-0000-0000-000000000160';
  task_id uuid := '00000000-0000-0000-0000-000000000161';
  report_id uuid := '00000000-0000-0000-0000-000000000162';
  task_gen bigint;
  result jsonb;
begin
  insert into public.field_crews(id,name,member_profile_ids,shift_start,shift_end,max_tasks_per_shift,
    max_volume_m3,max_weight_kg)
    values(crew_id,'Feedback test crew',array[actor_id],'08:00','17:00',10,8,2000);
  insert into public.cleanup_tasks(id,title,assigned_crew_ids,assigned_field_crew_id,route_status,report_ids)
    values(task_id,'Feedback test site',array[actor_id],crew_id,'ready',array[report_id]);
  insert into public.reports(id,user_id,title,location,cleanup_task_id)
    values(report_id,actor_id,'Feedback report',
      extensions.st_setsrid(extensions.st_makepoint(121,14),4326)::extensions.geography,task_id);
  select assignment_generation into task_gen from public.cleanup_tasks where id=task_id;

  result := public.record_field_load(actor_id,'load-1',jsonb_build_object(
    'task_id',task_id,'assignment_generation',task_gen,
    'event_type','load_observation','fill_percent',80,'actual_volume_m3',4,
    'actual_weight_kg',700,'observed_at',now()));
  if result->>'status'<>'applied' or
    (select starting_volume_m3 from public.field_crews where id=crew_id)<>4 then
    raise exception 'Actual vehicle load was not recorded: %',result;
  end if;
  result := public.record_field_load(actor_id,'load-2',jsonb_build_object(
    'task_id',task_id,'assignment_generation',task_gen,
    'event_type','disposal','observed_at',now()));
  if result->>'status'<>'applied' or
    (select starting_volume_m3 from public.field_crews where id=crew_id)<>0 or
    (select starting_weight_kg from public.field_crews where id=crew_id)<>0 then
    raise exception 'Disposal did not reset measured load: %',result;
  end if;
  result := public.record_field_load(actor_id,'load-2',jsonb_build_object(
    'task_id',task_id,'assignment_generation',task_gen,
    'event_type','disposal','observed_at',now()));
  if result->>'replayed'<>'true' or
    (select count(*) from public.field_load_events e where e.task_id=regression.task_id)<>2 then
    raise exception 'Load replay duplicated event';
  end if;

  result := public.submit_field_failure(actor_id,'failure-1',jsonb_build_object(
    'task_id',task_id,'assignment_generation',task_gen,
    'reason_code','site_inaccessible','notes','Gate locked',
    'evidence_refs',jsonb_build_array('https://evidence.example/gate.jpg'),
    'observed_at',now()));
  if result->>'status'<>'applied' or
    (select status::text from public.cleanup_tasks where id=task_id)<>'cancelled' or
    (select count(*) from public.dispatch_access_blocks b where b.report_id=regression.report_id and b.cleared_at is null)<>1 then
    raise exception 'Site failure did not halt and block location: %',result;
  end if;
  if (select count(*) from public.field_task_failure_events e where e.task_id=regression.task_id)<>1 then
    raise exception 'Failure evidence was not retained';
  end if;
end $$;
