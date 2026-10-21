do $$
declare
  first_crew uuid := '00000000-0000-0000-0000-000000000002';
  second_crew uuid := '00000000-0000-0000-0000-000000000003';
  test_task uuid := '00000000-0000-0000-0000-000000000150';
  test_report uuid := '00000000-0000-0000-0000-000000000151';
  first_receipt public.field_assignment_receipts;
  payload jsonb;
  result jsonb;
begin
  insert into public.cleanup_tasks(id,title,assigned_crew_ids,route_status,report_ids)
    values(test_task,'Offline reconciliation',array[first_crew],'ready',array[test_report]);
  insert into public.reports(id,user_id,title,location,cleanup_task_id)
    values(test_report,first_crew,'Offline test site',
      extensions.st_setsrid(extensions.st_makepoint(121,14),4326)::extensions.geography,test_task);
  select * into first_receipt from public.field_assignment_receipts
    where task_id=test_task and report_id=test_report and crew_id=first_crew;
  if not found then raise exception 'Assignment receipt not issued'; end if;
  payload := jsonb_build_object('task_id',test_task,'report_id',test_report,
    'crew_id',first_crew,'assignment_generation',first_receipt.assignment_generation,
    'report_claim_generation',first_receipt.report_claim_generation,
    'outcome','cleaned','observed_at',now(),'evidence_refs',jsonb_build_array('https://evidence.example/first.jpg'));
  result := public.reconcile_report_outcome(first_crew,'offline-cleaned-1',payload);
  if result->>'status' <> 'applied' or (select status::text from public.reports where id=test_report) <> 'resolved' then
    raise exception 'Current valid receipt did not clean report: %',result;
  end if;
  if (select count(*) from public.report_resolution_events where report_id=test_report) <> 1 then
    raise exception 'Physical cleanup provenance missing';
  end if;
  result := public.reconcile_report_outcome(first_crew,'offline-cleaned-1',payload);
  if result->>'status' <> 'applied' or result->>'replayed' <> 'true' then
    raise exception 'Operation replay was not immutable: %',result;
  end if;
  result := public.reconcile_report_outcome(first_crew,'offline-ghost-1',payload || '{"outcome":"already_resolved"}'::jsonb);
  if result->>'status' <> 'acknowledged_already_resolved' then
    raise exception 'Successful earlier cleanup was not acknowledged: %',result;
  end if;
  update public.reports set status='unresolved',lgu_resolved_at=null where id=test_report;
  result := public.reconcile_report_outcome(first_crew,'offline-ghost-2',payload || '{"outcome":"already_resolved"}'::jsonb);
  if result->>'status' <> 'verification_required' then
    raise exception 'Reopened report was treated as cleaned: %',result;
  end if;
  update public.cleanup_tasks set assigned_crew_ids=array[second_crew] where id=test_task;
  result := public.reconcile_report_outcome(first_crew,'offline-cleaned-2',payload);
  if result->>'status' <> 'contested' or
    (select route_status from public.cleanup_tasks where id=test_task) <> 'needs_replan' then
    raise exception 'Stale physical completion was not held for review: %',result;
  end if;
  if (select count(*) from public.report_resolution_events where report_id=test_report) <> 1 then
    raise exception 'Contested cleanup incorrectly earned credit';
  end if;
  result := public.reconcile_report_outcome(first_crew,'offline-bad-1',
    payload || '{"assignment_generation":999}'::jsonb);
  if result->>'status' <> 'rejected' then raise exception 'Forged receipt accepted: %',result; end if;
end $$;
