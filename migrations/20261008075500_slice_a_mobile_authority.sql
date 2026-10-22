begin;
-- All dispatch mutations go through authenticated backend handlers and service-only RPCs.
revoke insert,update,delete,truncate,references,trigger on public.cleanup_tasks,public.clusters,
  public.dispatch_plans,public.dispatch_plan_items,public.field_crews,public.crew_routes,public.route_waypoints,
  public.optimization_runs,public.optimization_settings,public.optimization_templates,
  public.work_time_configuration,public.sweeper_configuration,public.sweeper_audit_log,
  public.fc_operation_log,public.fc_conflict_audit from anon,authenticated;
revoke insert,update,delete,truncate,references,trigger on public.profiles from anon,authenticated;
grant update(full_name,avatar_url,data_consent) on public.profiles to authenticated;
revoke insert,update,delete,truncate,references,trigger on public.reports from anon,authenticated;
grant insert(user_id,title,description,issue_type,location,on_private_property,property_owner_consent_status,idempotency_key)
  on public.reports to authenticated;
-- This legacy simple view is writable and originally runs with the owner's
-- privileges. Keep its SELECT behavior subject to the caller's report RLS.
alter view public.reports_view set (security_invoker = true);
revoke insert,update,delete,truncate,references,trigger on public.reports_view from anon,authenticated;
alter table public.cleanup_tasks enable row level security;
drop policy if exists "Enable read access for authenticated users" on public.cleanup_tasks;
create policy workflow_task_read on public.cleanup_tasks for select to authenticated using (
  public.get_auth_user_role()::text in ('admin','officer') or
  (public.get_auth_user_role()::text='field_crew' and auth.uid()=any(coalesce(assigned_crew_ids,'{}'::uuid[]))));
do $$ declare target text;
begin
  foreach target in array array['dispatch_plans','dispatch_plan_items','optimization_runs','optimization_settings','optimization_templates','work_time_configuration','sweeper_configuration','sweeper_audit_log','fc_operation_log','fc_conflict_audit'] loop
    execute format('alter table public.%I enable row level security',target);
    execute format('create policy workflow_desk_read on public.%I for select to authenticated using (public.get_auth_user_role()::text in (''admin'',''officer''))',target);
  end loop;
end; $$;
alter table public.field_crews enable row level security;
create policy workflow_crew_read on public.field_crews for select to authenticated using (
  public.get_auth_user_role()::text in ('admin','officer') or auth.uid()=team_lead_profile_id or auth.uid()=any(coalesce(member_profile_ids,'{}'::uuid[])));
alter table public.crew_routes enable row level security;
create policy workflow_route_read on public.crew_routes for select to authenticated using (
  public.get_auth_user_role()::text in ('admin','officer') or exists(select 1 from public.field_crews c where c.id=crew_id
    and (auth.uid()=c.team_lead_profile_id or auth.uid()=any(coalesce(c.member_profile_ids,'{}'::uuid[])))));
alter table public.route_waypoints enable row level security;
create policy workflow_waypoint_read on public.route_waypoints for select to authenticated using (
  exists(select 1 from public.crew_routes r where r.id=crew_route_id));
create index reports_active_task_claim on public.reports(cleanup_task_id) where cleanup_task_id is not null;
create index reports_active_cluster_membership on public.reports(cluster_id) where cluster_id is not null;
create index tasks_active_field_crew on public.cleanup_tasks(assigned_field_crew_id) where status not in ('completed','cancelled');
do $$ declare signature text;
begin
  foreach signature in array array['public.upsert_cluster_for_reports_old(uuid[],text,text,double precision)',
    'public.upsert_cluster_for_reports(uuid[],text,text,numeric)','public.create_outlier_clusters()'] loop
    if to_regprocedure(signature) is not null then
      execute format('revoke all on function %s from public,anon,authenticated,service_role',signature);
    end if;
  end loop;
end; $$;

create function public.change_field_crew_member(crew_id uuid, actor uuid, member_id uuid, action text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare crew public.field_crews;
begin
  perform workflow_private.require_desk_actor(actor);
  if action is null or action not in ('add','remove') or member_id is null then raise exception 'Invalid membership action'; end if;
  perform pg_advisory_xact_lock(72631010);
  select * into crew from public.field_crews where id=crew_id for update;
  if not found then raise exception 'Crew not found'; end if;
  if action='add' then
    if not exists(select 1 from public.profiles where id=member_id and role::text='field_crew') then raise exception 'Member must have field_crew role'; end if;
    if exists(select 1 from public.field_crews where id<>crew_id and (member_id=any(coalesce(member_profile_ids,'{}'::uuid[])) or team_lead_profile_id=member_id)) then raise exception 'Member already belongs to another crew'; end if;
    update public.field_crews set member_profile_ids=array(select distinct x from unnest(coalesce(crew.member_profile_ids,'{}'::uuid[])||array[member_id]) x),updated_at=now() where id=crew_id returning * into crew;
  else
    update public.field_crews set member_profile_ids=array_remove(member_profile_ids,member_id),
      team_lead_profile_id=case when team_lead_profile_id=member_id then null else team_lead_profile_id end,updated_at=now() where id=crew_id returning * into crew;
  end if;
  return to_jsonb(crew);
end; $$;
revoke all on function public.change_field_crew_member(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.change_field_crew_member(uuid,uuid,uuid,text) to service_role;
create function public.set_cluster_queue_status(cluster_id uuid, actor uuid, next_status text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare cluster public.clusters;
begin
  perform workflow_private.require_desk_actor(actor);
  if next_status is null or next_status not in ('unresolved','prioritized','queued','monitoring','needs_verification') then raise exception 'Use task outcomes or block review for execution states'; end if;
  select * into cluster from public.clusters where id=cluster_id for update;
  if not found then raise exception 'Cluster not found'; end if;
  if cluster.status::text in ('scheduled','in_progress','deferred') or exists(select 1 from public.reports where reports.cluster_id=cluster.id and cleanup_task_id is not null) then raise exception 'Active or blocked cluster cannot be manually requeued'; end if;
  update public.clusters set status=next_status::public.cluster_status where id=cluster.id returning * into cluster;
  return to_jsonb(cluster);
end; $$;
revoke all on function public.set_cluster_queue_status(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.set_cluster_queue_status(uuid,uuid,text) to service_role;

create function workflow_private.bump_report_version() returns trigger
language plpgsql set search_path='' as $$
begin
  -- Server lifecycle/assignment changes invalidate every cached mobile snapshot too.
  new.fc_version:=old.fc_version+1;
  return new;
end; $$;
create trigger zy_workflow_report_version before update on public.reports
  for each row execute function workflow_private.bump_report_version();
create trigger zy_workflow_task_version before update on public.cleanup_tasks
  for each row execute function workflow_private.bump_report_version();

create function public.apply_fc_operation(actor uuid, operation_id text, operation_type text, entity_id uuid,
  entity_type text, payload jsonb, base_version bigint default 0)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare prior public.fc_operation_log; report public.reports; task public.cleanup_tasks; patched public.reports;
  actor_role text; claim uuid; result jsonb; note public.response_log; allowed text[]; key text; identical boolean;
begin
  if operation_id is null or length(operation_id) not between 1 and 200 or jsonb_typeof(payload) is distinct from 'object'
    or base_version is null or base_version<0 then raise exception 'Invalid sync operation' using errcode='22023'; end if;
  select role::text into actor_role from public.profiles where id=actor;
  if actor_role is null or actor_role not in ('admin','officer','field_crew') then raise exception 'Field operations access required' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(operation_id,72631009));
  select * into prior from public.fc_operation_log l where l.operation_id=apply_fc_operation.operation_id;
  if found then
    if prior.user_id<>actor or prior.entity_id<>entity_id::text or prior.operation_type::text<>operation_type then
      raise exception 'Operation ID belongs to another request' using errcode='42501';
    end if;
    return prior.result || jsonb_build_object('operation_id',operation_id,'replayed',true);
  end if;
  if operation_type='fc.task.mark_complete' and entity_type='task' then
    result:=public.submit_task_outcome(entity_id,actor,coalesce(payload->>'outcome','completed'),coalesce(payload->>'notes',''),
      payload->>'failure_class',base_version,operation_id);
  elsif entity_type='report' and operation_type in ('fc.report.update_status','fc.report.update_lifecycle_stage','fc.report.update_validation','fc.report.update_details','fc.note.add') then
    select cleanup_task_id into claim from public.reports where id=entity_id;
    if claim is not null then select * into task from public.cleanup_tasks where id=claim for update; end if;
    select * into report from public.reports where id=entity_id for update;
    if not found then raise exception 'Report not found' using errcode='P0002'; end if;
    if actor_role='field_crew' and (report.cleanup_task_id is distinct from claim or claim is null
      or task.status::text in ('completed','cancelled') or not workflow_private.can_execute_task(actor,task)) then
      raise exception 'Report is not assigned to this crew' using errcode='42501';
    end if;
    if operation_type='fc.note.add' then
      if nullif(btrim(coalesce(payload->>'action',payload->>'action_details')),'') is null then raise exception 'Note text required'; end if;
      insert into public.response_log(report_id,user_id,action_type,action_details)
        values(entity_id,actor,'manual_note',coalesce(payload->>'action',payload->>'action_details')) returning * into note;
      result:=jsonb_build_object('status','success','server_record',to_jsonb(note));
    else
      allowed:=case operation_type when 'fc.report.update_status' then array['status']
        when 'fc.report.update_lifecycle_stage' then array['stage']
        when 'fc.report.update_validation' then array['validation_status']
        else array['notes','stage'] end;
      for key in select jsonb_object_keys(payload) loop
        if not(key=any(allowed)) then raise exception 'Field is server-owned or unsupported: %',key using errcode='42501'; end if;
      end loop;
      if payload ? 'status' and payload->>'status' not in ('in_progress','resolved') then raise exception 'Use a classified task outcome for closure or failure'; end if;
      if report.status::text in ('resolved','completed','closed','rejected') then
        result:=jsonb_build_object('status','conflict','server_record',to_jsonb(report),'error_message','Report is terminal');
      else
        select bool_and(to_jsonb(report)->k is not distinct from payload->k) into identical from jsonb_object_keys(payload) k;
        if coalesce(identical,false) then result:=jsonb_build_object('status','success','server_record',to_jsonb(report));
        elsif base_version<>report.fc_version then
          result:=jsonb_build_object('status','conflict','server_record',to_jsonb(report),'error_message','Report version changed',
            'conflict_detail',jsonb_build_object('rule','first_accepted_wins','server_version',report.fc_version,'client_base_version',base_version));
        else
          patched:=jsonb_populate_record(report,payload);
          update public.reports set status=patched.status,stage=patched.stage,notes=patched.notes,validation_status=patched.validation_status,
            lgu_resolved_at=case when patched.status::text='resolved' then now() else lgu_resolved_at end,updated_at=now()
            where id=entity_id returning * into report;
          result:=jsonb_build_object('status','success','server_record',to_jsonb(report));
        end if;
      end if;
    end if;
  else raise exception 'Unsupported sync operation' using errcode='22023'; end if;
  result:=result||jsonb_build_object('operation_id',operation_id);
  if result->>'status'='conflict' then
    insert into public.fc_conflict_audit(operation_id,user_id,operation_type,entity_id,entity_type,outcome,client_base_version,server_version,payload,server_state_snapshot,reason)
      values(operation_id,actor,operation_type::public.sync_operation_type,entity_id::text,entity_type::public.sync_entity_type,'rejected',base_version,
        (result->'server_record'->>'fc_version')::bigint,payload,result->'server_record',result->>'error_message');
  end if;
  insert into public.fc_operation_log(operation_id,user_id,operation_type,entity_id,entity_type,status,result)
    values(operation_id,actor,operation_type::public.sync_operation_type,entity_id::text,entity_type::public.sync_entity_type,result->>'status',result);
  return result;
end; $$;
revoke all on function public.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint) from public,anon,authenticated;
grant execute on function public.apply_fc_operation(uuid,text,text,uuid,text,jsonb,bigint) to service_role;
create function public.set_task_photo(task_id uuid, actor uuid, slot text, url text, photo_hash text, expected_version bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare task public.cleanup_tasks;
begin
  select * into task from public.cleanup_tasks where id=task_id for update;
  if not found or not workflow_private.can_execute_task(actor,task) then raise exception 'Task access denied' using errcode='42501'; end if;
  if slot is null or slot not in ('before','after') then raise exception 'Invalid photo slot'; end if;
  if task.status::text in ('completed','cancelled') or expected_version is distinct from task.fc_version then
    return jsonb_build_object('status','conflict','server_record',to_jsonb(task));
  end if;
  update public.cleanup_tasks set before_photo_url=case when slot='before' then url else before_photo_url end,
    after_photo_url=case when slot='after' then url else after_photo_url end,
    before_photo_hash=case when slot='before' then photo_hash else before_photo_hash end,
    after_photo_hash=case when slot='after' then photo_hash else after_photo_hash end,
    status=case when slot='before' and url is not null then 'in_progress'::public.cleanup_task_status else status end,
    fc_version=fc_version+1 where id=task_id returning * into task;
  return jsonb_build_object('status','success','server_record',to_jsonb(task));
end; $$;
revoke all on function public.set_task_photo(uuid,uuid,text,text,text,bigint) from public,anon,authenticated;
grant execute on function public.set_task_photo(uuid,uuid,text,text,text,bigint) to service_role;
revoke all on all functions in schema workflow_private from public,anon,authenticated;
grant execute on all functions in schema workflow_private to service_role;
commit;
