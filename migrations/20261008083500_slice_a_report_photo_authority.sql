begin;
create function public.set_report_photo(report_id uuid, actor uuid, slot text, url text,
  photo_hash text, expected_version bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare claim uuid; task public.cleanup_tasks; report public.reports; prior_url text;
begin
  if slot not in ('before','after') or expected_version is null or expected_version<0 then
    raise exception 'Invalid report photo request' using errcode='22023';
  end if;
  select cleanup_task_id into claim from public.reports where id=report_id;
  if claim is null then raise exception 'Report is not assigned' using errcode='42501'; end if;
  select * into task from public.cleanup_tasks where id=claim for update;
  select * into report from public.reports where id=report_id for update;
  if not found or report.cleanup_task_id is distinct from claim or task.status::text in ('completed','cancelled')
    or not workflow_private.can_execute_task(actor,task) then
    raise exception 'Report is not assigned to this crew' using errcode='42501';
  end if;
  if report.status::text in ('resolved','completed','closed','rejected') then
    return jsonb_build_object('status','conflict','error_message','Report is terminal','server_record',to_jsonb(report));
  end if;
  if report.fc_version<>expected_version then
    return jsonb_build_object('status','conflict','error_message','Report version changed','server_record',to_jsonb(report));
  end if;
  prior_url:=case when slot='before' then report.before_photo_url else report.after_photo_url end;
  update public.reports set
    before_photo_url=case when slot='before' then url else before_photo_url end,
    after_photo_url=case when slot='after' then url else after_photo_url end,
    before_photo_hash=case when slot='before' then photo_hash else before_photo_hash end,
    after_photo_hash=case when slot='after' then photo_hash else after_photo_hash end,
    updated_at=now() where id=report_id returning * into report;
  return jsonb_build_object('status','success','server_record',to_jsonb(report),'previous_url',prior_url);
end; $$;
revoke all on function public.set_report_photo(uuid,uuid,text,text,text,bigint) from public,anon,authenticated;
grant execute on function public.set_report_photo(uuid,uuid,text,text,text,bigint) to service_role;
commit;
