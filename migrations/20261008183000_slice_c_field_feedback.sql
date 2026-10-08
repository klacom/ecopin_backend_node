begin;

alter type public.sync_operation_type add value if not exists 'fc.load.record';
alter type public.sync_operation_type add value if not exists 'fc.task.failure';

create table public.field_load_events (
  id uuid primary key default gen_random_uuid(),
  operation_id text not null unique,
  task_id uuid not null references public.cleanup_tasks(id),
  field_crew_id uuid not null references public.field_crews(id),
  actor_id uuid not null references public.profiles(id),
  assignment_generation bigint not null check (assignment_generation > 0),
  event_type text not null check (event_type in ('load_observation','disposal')),
  fill_percent numeric(5,2) check (fill_percent between 0 and 100),
  actual_volume_m3 numeric(10,3) check (actual_volume_m3 >= 0),
  actual_weight_kg numeric(12,2) check (actual_weight_kg >= 0),
  observed_at timestamptz not null,
  submitted_at timestamptz not null default now(),
  notes text not null default ''
);
create index field_load_events_crew_time on public.field_load_events(field_crew_id, observed_at desc);

create table public.field_task_failure_events (
  id uuid primary key default gen_random_uuid(),
  operation_id text not null unique,
  task_id uuid not null references public.cleanup_tasks(id),
  actor_id uuid not null references public.profiles(id),
  assignment_generation bigint not null check (assignment_generation > 0),
  reason_code text not null check (reason_code in
    ('site_inaccessible','safety_hazard','vehicle_failure','crew_unavailable')),
  failure_class text not null check (failure_class in ('site','safety','transient')),
  evidence_refs jsonb not null check (jsonb_typeof(evidence_refs) = 'array'),
  notes text not null check (length(btrim(notes)) > 0),
  observed_at timestamptz not null,
  submitted_at timestamptz not null default now()
);
create index field_task_failure_events_task_time on public.field_task_failure_events(task_id, observed_at desc);

alter table public.field_load_events enable row level security;
alter table public.field_task_failure_events enable row level security;
revoke all on public.field_load_events,public.field_task_failure_events from public,anon,authenticated;
grant select,insert on public.field_load_events,public.field_task_failure_events to service_role;

create function public.record_field_load(actor uuid, operation_id text, payload jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  prior public.fc_operation_log;
  task public.cleanup_tasks;
  crew public.field_crews;
  event public.field_load_events;
  result jsonb;
  v_task_id uuid;
  v_type text;
  v_volume numeric;
  v_weight numeric;
  v_fill numeric;
  v_observed timestamptz;
begin
  if operation_id is null or length(operation_id) not between 1 and 200
    or jsonb_typeof(payload) is distinct from 'object' then
    raise exception 'Invalid load event' using errcode='22023';
  end if;
  v_task_id := (payload->>'task_id')::uuid;
  v_type := payload->>'event_type';
  v_volume := nullif(payload->>'actual_volume_m3','')::numeric;
  v_weight := nullif(payload->>'actual_weight_kg','')::numeric;
  v_fill := nullif(payload->>'fill_percent','')::numeric;
  v_observed := (payload->>'observed_at')::timestamptz;
  if v_task_id is null or v_type is null or v_type not in ('load_observation','disposal') or v_observed is null
    or v_observed > now() + interval '5 minutes' or
    (v_type='load_observation' and v_volume is null and v_weight is null and v_fill is null)
    or coalesce(v_volume,0)<0 or coalesce(v_weight,0)<0 or coalesce(v_fill,0)<0 or coalesce(v_fill,0)>100 then
    raise exception 'Load event needs a valid measurement and time' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(operation_id,72631009));
  select * into prior from public.fc_operation_log l where l.operation_id=record_field_load.operation_id;
  if found then
    if prior.user_id<>actor or prior.entity_id<>v_task_id::text or prior.operation_type::text<>'fc.load.record' then
      raise exception 'Operation ID belongs to another request' using errcode='42501';
    end if;
    return prior.result || jsonb_build_object('replayed',true);
  end if;
  select * into task from public.cleanup_tasks where id=v_task_id for update;
  if not found or task.assignment_generation is distinct from (payload->>'assignment_generation')::bigint
    or task.assigned_field_crew_id is null or task.status::text in ('completed','cancelled')
    or not workflow_private.can_execute_task(actor,task) then
    result:=jsonb_build_object('operation_id',operation_id,'status','rejected',
      'error_message','Task assignment is no longer active','server_record',to_jsonb(task));
    insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
      values(operation_id,actor,'fc.load.record',v_task_id::text,'task','rejected',result,'infinity');
    return result;
  end if;
  select * into crew from public.field_crews where id=task.assigned_field_crew_id for update;
  if not found then raise exception 'Assigned vehicle not found' using errcode='P0002'; end if;
  if v_type='disposal' then
    v_volume:=0; v_weight:=0; v_fill:=0;
  end if;
  insert into public.field_load_events
    (operation_id,task_id,field_crew_id,actor_id,assignment_generation,event_type,
     fill_percent,actual_volume_m3,actual_weight_kg,observed_at,notes)
    values(operation_id,v_task_id,crew.id,actor,task.assignment_generation,v_type,
      v_fill,v_volume,v_weight,v_observed,coalesce(payload->>'notes',''))
    returning * into event;
  update public.field_crews set
    starting_volume_m3=case when v_volume is not null then least(v_volume,coalesce(max_volume_m3,v_volume))
      when v_fill is not null and max_volume_m3 is not null then max_volume_m3*v_fill/100
      else starting_volume_m3 end,
    starting_weight_kg=case when v_weight is not null then least(v_weight,coalesce(max_weight_kg,v_weight))
      else starting_weight_kg end,
    load_measured_at=now()
    where id=crew.id;
  result:=jsonb_build_object('operation_id',operation_id,'status','applied',
    'server_record',to_jsonb(task),'load_event_id',event.id);
  insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
    values(operation_id,actor,'fc.load.record',v_task_id::text,'task','applied',result,'infinity');
  return result;
end;
$$;

create function public.submit_field_failure(actor uuid, operation_id text, payload jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  prior public.fc_operation_log;
  task public.cleanup_tasks;
  result jsonb;
  v_task_id uuid;
  v_reason text;
  v_class text;
  v_observed timestamptz;
begin
  if operation_id is null or length(operation_id) not between 1 and 200
    or jsonb_typeof(payload) is distinct from 'object'
    or jsonb_typeof(payload->'evidence_refs') is distinct from 'array'
    or jsonb_array_length(payload->'evidence_refs')=0
    or nullif(btrim(payload->>'notes'),'') is null then
    raise exception 'Failure reason, notes and photo evidence are required' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_array_elements_text(payload->'evidence_refs') e(ref)
    where e.ref !~ '^https://[^[:space:]]+$') then
    raise exception 'Failure photo must be uploaded first' using errcode='22023';
  end if;
  v_task_id := (payload->>'task_id')::uuid;
  v_reason := payload->>'reason_code';
  v_observed := (payload->>'observed_at')::timestamptz;
  v_class := case v_reason when 'site_inaccessible' then 'site'
    when 'safety_hazard' then 'safety'
    when 'vehicle_failure' then 'transient'
    when 'crew_unavailable' then 'transient' else null end;
  if v_task_id is null or v_class is null or v_observed is null
    or v_observed > now() + interval '5 minutes' then
    raise exception 'Invalid failure receipt' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(operation_id,72631009));
  select * into prior from public.fc_operation_log l where l.operation_id=submit_field_failure.operation_id;
  if found then
    if prior.user_id<>actor or prior.entity_id<>v_task_id::text or prior.operation_type::text<>'fc.task.failure' then
      raise exception 'Operation ID belongs to another request' using errcode='42501';
    end if;
    return prior.result || jsonb_build_object('replayed',true);
  end if;
  select * into task from public.cleanup_tasks where id=v_task_id for update;
  if not found or task.assignment_generation is distinct from (payload->>'assignment_generation')::bigint
    or task.status::text in ('completed','cancelled') or not workflow_private.can_execute_task(actor,task) then
    result:=jsonb_build_object('operation_id',operation_id,'status','rejected',
      'error_message','Task assignment is no longer active','server_record',to_jsonb(task));
    insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
      values(operation_id,actor,'fc.task.failure',v_task_id::text,'task','rejected',result,'infinity');
    return result;
  end if;
  result:=public.submit_task_outcome(v_task_id,actor,'unable_to_complete',
    concat(v_reason,': ',payload->>'notes'),v_class,null,operation_id);
  insert into public.field_task_failure_events
    (operation_id,task_id,actor_id,assignment_generation,reason_code,failure_class,evidence_refs,notes,observed_at)
    values(operation_id,v_task_id,actor,task.assignment_generation,v_reason,v_class,
      payload->'evidence_refs',payload->>'notes',v_observed);
  result:=jsonb_build_object('operation_id',operation_id,'status','applied',
    'server_record',result->'server_record');
  insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
    values(operation_id,actor,'fc.task.failure',v_task_id::text,'task','applied',result,'infinity');
  return result;
end;
$$;

revoke all on function public.record_field_load(uuid,text,jsonb),
  public.submit_field_failure(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.record_field_load(uuid,text,jsonb),
  public.submit_field_failure(uuid,text,jsonb) to service_role;

commit;
