begin;
alter table public.reports add column if not exists after_photos jsonb not null default '[]'::jsonb
  check (jsonb_typeof(after_photos)='array' and jsonb_array_length(after_photos)<=5);
revoke select(after_photos),update(after_photos) on public.reports from anon,authenticated;
update public.reports set after_photos=jsonb_build_array(jsonb_build_object(
  'id','legacy','url',after_photo_url,'hash',after_photo_hash))
  where nullif(after_photo_url,'') is not null and jsonb_array_length(after_photos)=0;

create or replace function public.set_report_before_photo(report_id uuid, actor uuid, photo_key text,
  url text, photo_hash text, expected_version bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare claim uuid; task public.cleanup_tasks; report public.reports; photos jsonb; prior jsonb;
begin
  if nullif(photo_key,'') is null or length(photo_key)>80 or expected_version is null or expected_version<0 then
    raise exception 'Invalid before photo request' using errcode='22023';
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
  photos:=report.before_photos;
  if jsonb_array_length(photos)=0 and nullif(report.before_photo_url,'') is not null then
    photos:=jsonb_build_array(jsonb_build_object('id','legacy','url',report.before_photo_url,'hash',report.before_photo_hash));
  end if;
  select p into prior from jsonb_array_elements(photos) p where p->>'id'=photo_key;
  if url is not null and prior is not null then
    if prior->>'hash' is distinct from photo_hash then raise exception 'Photo ID already used'; end if;
    return jsonb_build_object('status','success','server_record',to_jsonb(report),'photo_id',photo_key,'url',prior->>'url');
  end if;
  if report.fc_version<>expected_version then
    return jsonb_build_object('status','conflict','error_message','Report version changed','server_record',to_jsonb(report));
  end if;
  if url is null then
    select coalesce(jsonb_agg(p),'[]'::jsonb) into photos from jsonb_array_elements(photos) p where p->>'id'<>photo_key;
  else
    if jsonb_array_length(photos)>=5 then raise exception 'Maximum 5 Before photos per report'; end if;
    if exists(select 1 from jsonb_array_elements(photos) p where p->>'hash'=photo_hash) then
      raise exception 'This Before photo has already been uploaded';
    end if;
    photos:=photos||jsonb_build_array(jsonb_build_object('id',photo_key,'url',url,'hash',photo_hash));
  end if;
  update public.reports set before_photos=photos,
    before_photo_url=photos->0->>'url', before_photo_hash=photos->0->>'hash',
    updated_at=now() where id=report_id returning * into report;
  return jsonb_build_object('status','success','server_record',to_jsonb(report),
    'photo_id',photo_key,'url',url,'previous_url',prior->>'url');
end; $$;
revoke all on function public.set_report_before_photo(uuid,uuid,text,text,text,bigint) from public,anon,authenticated;
grant execute on function public.set_report_before_photo(uuid,uuid,text,text,text,bigint) to service_role;

create or replace function public.set_report_after_photo(report_id uuid, actor uuid, photo_key text,
  url text, photo_hash text, expected_version bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare claim uuid; task public.cleanup_tasks; report public.reports; photos jsonb; prior jsonb;
begin
  if nullif(photo_key,'') is null or length(photo_key)>80 or expected_version is null or expected_version<0 then
    raise exception 'Invalid after photo request' using errcode='22023';
  end if;
  select cleanup_task_id into claim from public.reports where id=report_id;
  if claim is null then raise exception 'Report is not assigned' using errcode='42501'; end if;
  select * into task from public.cleanup_tasks where id=claim for update;
  select * into report from public.reports where id=report_id for update;
  if not found or report.cleanup_task_id is distinct from claim or task.status::text in ('completed','cancelled')
    or not workflow_private.can_execute_task(actor,task) then
    raise exception 'Report is not assigned to this crew' using errcode='42501';
  end if;
  if report.status::text in ('resolved','completed','closed','rejected') and not (
    report.status::text = 'resolved' and nullif(url,'') is not null
  ) then
    return jsonb_build_object('status','conflict','error_message','Report is terminal','server_record',to_jsonb(report));
  end if;
  photos:=report.after_photos;
  if jsonb_array_length(photos)=0 and nullif(report.after_photo_url,'') is not null then
    photos:=jsonb_build_array(jsonb_build_object('id','legacy','url',report.after_photo_url,'hash',report.after_photo_hash));
  end if;
  select p into prior from jsonb_array_elements(photos) p where p->>'id'=photo_key;
  if url is not null and prior is not null then
    if prior->>'hash' is distinct from photo_hash then raise exception 'Photo ID already used'; end if;
    return jsonb_build_object('status','success','server_record',to_jsonb(report),'photo_id',photo_key,'url',prior->>'url');
  end if;
  if report.fc_version<>expected_version then
    return jsonb_build_object('status','conflict','error_message','Report version changed','server_record',to_jsonb(report));
  end if;
  if url is null then
    select coalesce(jsonb_agg(p),'[]'::jsonb) into photos from jsonb_array_elements(photos) p where p->>'id'<>photo_key;
  else
    if jsonb_array_length(photos)>=5 then raise exception 'Maximum 5 After photos per report'; end if;
    if exists(select 1 from jsonb_array_elements(photos) p where p->>'hash'=photo_hash) then
      raise exception 'This After photo has already been uploaded';
    end if;
    photos:=photos||jsonb_build_array(jsonb_build_object('id',photo_key,'url',url,'hash',photo_hash));
  end if;
  update public.reports set after_photos=photos,
    after_photo_url=photos->0->>'url', after_photo_hash=photos->0->>'hash',
    updated_at=now() where id=report_id returning * into report;
  return jsonb_build_object('status','success','server_record',to_jsonb(report),
    'photo_id',photo_key,'url',url,'previous_url',prior->>'url');
end; $$;
revoke all on function public.set_report_after_photo(uuid,uuid,text,text,text,bigint) from public,anon,authenticated;
grant execute on function public.set_report_after_photo(uuid,uuid,text,text,text,bigint) to service_role;

create or replace function public.set_report_photo(report_id uuid, actor uuid, slot text, url text,
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
  if report.status::text in ('resolved','completed','closed','rejected') and not (
    report.status::text = 'resolved' and slot = 'after' and nullif(url,'') is not null
  ) then
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
