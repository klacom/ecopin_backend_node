do $$
declare
  crew_id uuid := '00000000-0000-0000-0000-000000000010';
  other_crew_id uuid := '00000000-0000-0000-0000-000000000011';
  task_id uuid := '00000000-0000-0000-0000-000000000140';
  report_id uuid := '00000000-0000-0000-0000-000000000141';
  task_gen bigint;
  claim_gen bigint;
begin
  insert into public.field_crews(id,name,shift_start,shift_end,max_tasks_per_shift)
    values(other_crew_id,'Receipt alternate crew','08:00','17:00',10);
  insert into public.cleanup_tasks(id,title,assigned_field_crew_id,assigned_crew_ids)
    values(task_id,'Receipt test',crew_id,array[crew_id]);
  select assignment_generation into task_gen from public.cleanup_tasks where id=task_id;
  if task_gen <> 1 then raise exception 'Initial task receipt missing: %',task_gen; end if;
  update public.cleanup_tasks set notes='same assignment' where id=task_id;
  if (select assignment_generation from public.cleanup_tasks where id=task_id) <> task_gen then
    raise exception 'Non-assignment task edit invalidated receipt';
  end if;
  update public.cleanup_tasks set assigned_field_crew_id=other_crew_id where id=task_id;
  if (select assignment_generation from public.cleanup_tasks where id=task_id) <> task_gen+1 then
    raise exception 'Reassignment did not advance task receipt';
  end if;

  insert into public.reports(id,cleanup_task_id)
    values(report_id,task_id);
  select report_claim_generation into claim_gen from public.reports where id=report_id;
  if claim_gen <> 1 then raise exception 'Initial report claim receipt missing: %',claim_gen; end if;
  update public.reports set notes='same claim' where id=report_id;
  if (select report_claim_generation from public.reports where id=report_id) <> claim_gen then
    raise exception 'Non-claim report edit invalidated receipt';
  end if;
  update public.cleanup_tasks set status='cancelled' where id=task_id;
  if (select report_claim_generation from public.reports where id=report_id) <> claim_gen+1 then
    raise exception 'Claim release did not advance report receipt';
  end if;
end $$;
