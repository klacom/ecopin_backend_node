begin;

alter type public.sync_operation_type add value if not exists 'fc.report.reconcile';

create table public.field_assignment_receipts (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.cleanup_tasks(id),
  report_id uuid not null references public.reports(id),
  crew_id uuid not null references public.profiles(id),
  assignment_generation bigint not null check (assignment_generation > 0),
  report_claim_generation bigint not null check (report_claim_generation > 0),
  issued_at timestamptz not null default now(),
  unique (task_id, report_id, crew_id, assignment_generation, report_claim_generation)
);
create index field_assignment_receipts_report on public.field_assignment_receipts(report_id, issued_at desc);

create table public.report_resolution_events (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.reports(id),
  task_id uuid not null references public.cleanup_tasks(id),
  crew_id uuid not null references public.profiles(id),
  operation_id text not null unique,
  resolved_at timestamptz not null default now(),
  report_fc_version bigint not null,
  resolution_kind text not null default 'cleaned' check (resolution_kind = 'cleaned')
);
create index report_resolution_events_latest on public.report_resolution_events(report_id, resolved_at desc);

create table public.task_report_outcomes (
  id uuid primary key default gen_random_uuid(),
  operation_id text not null unique,
  task_id uuid not null references public.cleanup_tasks(id),
  report_id uuid not null references public.reports(id),
  crew_id uuid not null references public.profiles(id),
  receipt_id uuid not null references public.field_assignment_receipts(id),
  outcome text not null check (outcome in ('cleaned','already_resolved','unable','skipped')),
  disposition text not null check (disposition in ('applied','acknowledged_already_resolved','verification_required','contested')),
  observed_at timestamptz not null,
  submitted_at timestamptz not null default now(),
  evidence_refs jsonb not null default '[]'::jsonb check (jsonb_typeof(evidence_refs) = 'array'),
  notes text not null default '',
  resolution_event_id uuid references public.report_resolution_events(id)
);
create index task_report_outcomes_review on public.task_report_outcomes(disposition, submitted_at)
  where disposition in ('verification_required','contested');

alter table public.field_assignment_receipts enable row level security;
alter table public.report_resolution_events enable row level security;
alter table public.task_report_outcomes enable row level security;
revoke all on public.field_assignment_receipts,public.report_resolution_events,public.task_report_outcomes from public,anon,authenticated;
grant select,insert on public.field_assignment_receipts,public.report_resolution_events,public.task_report_outcomes to service_role;

create function workflow_private.issue_task_report_receipts() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.assignment_generation = 0 then return new; end if;
  if tg_op = 'UPDATE' then
    if new.assignment_generation is not distinct from old.assignment_generation then return new; end if;
  end if;
    insert into public.field_assignment_receipts
      (task_id,report_id,crew_id,assignment_generation,report_claim_generation)
    select new.id,r.id,crew.id,new.assignment_generation,r.report_claim_generation
      from public.reports r
      cross join lateral unnest(coalesce(new.assigned_crew_ids,'{}'::uuid[])) crew(id)
      where r.cleanup_task_id = new.id and r.report_claim_generation > 0
    on conflict do nothing;
  return new;
end;
$$;
create trigger workflow_issue_task_report_receipts
  after insert or update on public.cleanup_tasks
  for each row execute function workflow_private.issue_task_report_receipts();

create function workflow_private.issue_report_claim_receipts() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.cleanup_task_id is null or new.report_claim_generation = 0 then return new; end if;
  if tg_op = 'UPDATE' then
    if new.report_claim_generation is not distinct from old.report_claim_generation then return new; end if;
  end if;
    insert into public.field_assignment_receipts
      (task_id,report_id,crew_id,assignment_generation,report_claim_generation)
    select t.id,new.id,crew.id,t.assignment_generation,new.report_claim_generation
      from public.cleanup_tasks t
      cross join lateral unnest(coalesce(t.assigned_crew_ids,'{}'::uuid[])) crew(id)
      where t.id = new.cleanup_task_id and t.assignment_generation > 0
    on conflict do nothing;
  return new;
end;
$$;
create trigger workflow_issue_report_claim_receipts
  after insert or update on public.reports
  for each row execute function workflow_private.issue_report_claim_receipts();

insert into public.field_assignment_receipts
  (task_id,report_id,crew_id,assignment_generation,report_claim_generation)
select t.id,r.id,crew.id,t.assignment_generation,r.report_claim_generation
  from public.reports r
  join public.cleanup_tasks t on t.id = r.cleanup_task_id
  cross join lateral unnest(coalesce(t.assigned_crew_ids,'{}'::uuid[])) crew(id)
  where t.assignment_generation > 0 and r.report_claim_generation > 0
on conflict do nothing;

create function public.reconcile_report_outcome(actor uuid, operation_id text, payload jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  prior public.fc_operation_log;
  task public.cleanup_tasks;
  report public.reports;
  receipt public.field_assignment_receipts;
  resolution public.report_resolution_events;
  result jsonb;
  disposition text;
  observation timestamptz;
  requested_outcome text;
  v_report_id uuid;
  v_task_id uuid;
  v_crew_id uuid;
begin
  if operation_id is null or length(operation_id) not between 1 and 200
    or jsonb_typeof(payload) is distinct from 'object'
    or jsonb_typeof(payload->'evidence_refs') is distinct from 'array'
    or payload->>'outcome' is null
    or payload->>'outcome' not in ('cleaned','already_resolved','unable','skipped') then
    raise exception 'Invalid report outcome operation' using errcode='22023';
  end if;
  v_task_id := (payload->>'task_id')::uuid;
  v_report_id := (payload->>'report_id')::uuid;
  v_crew_id := (payload->>'crew_id')::uuid;
  requested_outcome := payload->>'outcome';
  observation := (payload->>'observed_at')::timestamptz;
  if v_task_id is null or v_report_id is null or v_crew_id is distinct from actor or observation is null
    or observation > now() + interval '5 minutes' then
    raise exception 'Invalid report outcome receipt' using errcode='22023';
  end if;
  if requested_outcome in ('cleaned','already_resolved') and jsonb_array_length(payload->'evidence_refs') = 0 then
    raise exception 'Physical outcome evidence is required' using errcode='22023';
  end if;
  if exists (select 1 from jsonb_array_elements_text(payload->'evidence_refs') e(ref)
    where e.ref !~ '^https://[^[:space:]]+$') then
    raise exception 'Outcome evidence must be uploaded first' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(operation_id,72631009));
  select * into prior from public.fc_operation_log l where l.operation_id = reconcile_report_outcome.operation_id;
  if found then
    if prior.user_id <> actor or prior.entity_id <> v_report_id::text or prior.operation_type::text <> 'fc.report.reconcile' then
      raise exception 'Operation ID belongs to another request' using errcode='42501';
    end if;
    return prior.result || jsonb_build_object('replayed',true);
  end if;

  select * into receipt from public.field_assignment_receipts ar
    where ar.task_id = v_task_id
      and ar.report_id = v_report_id
      and ar.crew_id = actor
      and ar.assignment_generation = (payload->>'assignment_generation')::bigint
      and ar.report_claim_generation = (payload->>'report_claim_generation')::bigint;
  if not found then
    result := jsonb_build_object('operation_id',operation_id,'status','rejected',
      'error_message','Assignment receipt is invalid');
    insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
      values(operation_id,actor,'fc.report.reconcile',v_report_id::text,'report','rejected',result,'infinity');
    return result;
  end if;

  select * into task from public.cleanup_tasks where id = v_task_id for update;
  select * into report from public.reports where id = v_report_id for update;
  if not found then raise exception 'Report no longer exists' using errcode='P0002'; end if;

  if requested_outcome = 'already_resolved' then
    select * into resolution from public.report_resolution_events e
      where e.report_id = v_report_id order by e.resolved_at desc limit 1;
    if found and report.status::text in ('resolved','completed','closed')
      and report.lgu_resolved_at is not null and report.lgu_resolved_at = resolution.resolved_at then
      disposition := 'acknowledged_already_resolved';
    else
      disposition := 'verification_required';
    end if;
  elsif requested_outcome = 'cleaned' then
    if task.assignment_generation = receipt.assignment_generation
      and task.route_status = 'ready'
      and task.status::text not in ('completed','cancelled')
      and actor = any(coalesce(task.assigned_crew_ids,'{}'::uuid[]))
      and report.report_claim_generation = receipt.report_claim_generation
      and report.cleanup_task_id = v_task_id
      and report.status::text not in ('resolved','completed','closed','rejected') then
      update public.reports set status='resolved',lgu_resolved_at=now(),updated_at=now()
        where id=v_report_id returning * into report;
      insert into public.report_resolution_events
        (report_id,task_id,crew_id,operation_id,report_fc_version,resolved_at)
        values(v_report_id,v_task_id,actor,operation_id,report.fc_version,report.lgu_resolved_at)
        returning * into resolution;
      disposition := 'applied';
    else
      disposition := 'contested';
      update public.cleanup_tasks set route_status='needs_replan'
        where id=report.cleanup_task_id and status::text not in ('completed','cancelled')
          and route_status <> 'needs_replan';
    end if;
  else
    disposition := 'applied';
  end if;

  insert into public.task_report_outcomes
    (operation_id,task_id,report_id,crew_id,receipt_id,outcome,disposition,observed_at,evidence_refs,notes,resolution_event_id)
    values(operation_id,v_task_id,v_report_id,actor,receipt.id,requested_outcome,disposition,observation,
      payload->'evidence_refs',coalesce(payload->>'notes',''),resolution.id);
  result := jsonb_build_object('operation_id',operation_id,'status',disposition,
    'server_record',to_jsonb(report));
  insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result,expires_at)
    values(operation_id,actor,'fc.report.reconcile',v_report_id::text,'report',disposition,result,'infinity');
  return result;
end;
$$;

revoke all on function public.reconcile_report_outcome(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.reconcile_report_outcome(uuid,text,jsonb) to service_role;
revoke all on function workflow_private.issue_task_report_receipts(),
  workflow_private.issue_report_claim_receipts() from public,anon,authenticated;
grant execute on function workflow_private.issue_task_report_receipts(),
  workflow_private.issue_report_claim_receipts() to service_role;

commit;
