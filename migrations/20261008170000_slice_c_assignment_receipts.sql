begin;

-- A claim generation identifies an individual report assignment. It advances
-- only when ownership changes, so ordinary status/photo edits keep the receipt.
alter table public.reports
  add column if not exists report_claim_generation bigint not null default 0;

update public.reports
set report_claim_generation = 1
where cleanup_task_id is not null and report_claim_generation = 0;

update public.cleanup_tasks
set assignment_generation = 1
where assignment_generation = 0
  and (assigned_field_crew_id is not null
       or cardinality(coalesce(assigned_crew_ids, '{}'::uuid[])) > 0);

create or replace function workflow_private.bump_report_claim_generation()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.cleanup_task_id is not null then
      new.report_claim_generation := greatest(new.report_claim_generation, 1);
    end if;
  elsif new.cleanup_task_id is distinct from old.cleanup_task_id then
    new.report_claim_generation := old.report_claim_generation + 1;
  else
    new.report_claim_generation := old.report_claim_generation;
  end if;
  return new;
end;
$$;

create trigger zx_workflow_report_claim_generation
  before insert or update on public.reports
  for each row execute function workflow_private.bump_report_claim_generation();

create or replace function workflow_private.bump_task_assignment_generation()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.assigned_field_crew_id is not null
       or cardinality(coalesce(new.assigned_crew_ids, '{}'::uuid[])) > 0 then
      new.assignment_generation := greatest(new.assignment_generation, 1);
    end if;
  elsif new.assigned_field_crew_id is distinct from old.assigned_field_crew_id
     or new.assigned_crew_ids is distinct from old.assigned_crew_ids
     or new.crew_route_id is distinct from old.crew_route_id
     or new.route_revision is distinct from old.route_revision then
    new.assignment_generation := old.assignment_generation + 1;
  else
    new.assignment_generation := old.assignment_generation;
  end if;
  return new;
end;
$$;

create trigger zx_workflow_task_assignment_generation
  before insert or update on public.cleanup_tasks
  for each row execute function workflow_private.bump_task_assignment_generation();

revoke all on function workflow_private.bump_report_claim_generation(),
  workflow_private.bump_task_assignment_generation() from public, anon, authenticated;
grant execute on function workflow_private.bump_report_claim_generation(),
  workflow_private.bump_task_assignment_generation() to service_role;

commit;
