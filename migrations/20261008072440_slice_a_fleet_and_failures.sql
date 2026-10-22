begin;
alter table public.cleanup_tasks add column completed_by uuid references public.profiles(id), add column completion_operation_id text;
create unique index task_completion_operation on public.cleanup_tasks(completion_operation_id) where completion_operation_id is not null;
create table public.dispatch_access_blocks(
  id uuid primary key default gen_random_uuid(),
  cluster_id uuid references public.clusters(id),
  report_id uuid references public.reports(id),
  task_id uuid references public.cleanup_tasks(id),
  reason text not null check(length(btrim(reason))>0),
  failure_class text not null check(failure_class in ('site','safety','unclassified')),
  blocked_by uuid references public.profiles(id),
  blocked_at timestamptz not null default now(),
  cleared_by uuid references public.profiles(id),
  cleared_at timestamptz,
  clearance_notes text,
  check((cluster_id is not null)::integer+(report_id is not null)::integer=1),
  check((cleared_at is null and cleared_by is null) or (cleared_at is not null and cleared_by is not null))
);
create unique index one_active_cluster_block on public.dispatch_access_blocks(cluster_id) where cleared_at is null and cluster_id is not null;
create unique index one_active_report_block on public.dispatch_access_blocks(report_id) where cleared_at is null and report_id is not null;
alter table public.dispatch_access_blocks enable row level security;
revoke all on public.dispatch_access_blocks from public,anon,authenticated;
grant select,insert,update on public.dispatch_access_blocks to service_role;
alter table public.reports drop constraint reports_cluster_id_fkey;
alter table public.reports add constraint reports_cluster_id_fkey foreign key(cluster_id) references public.clusters(id) on update cascade on delete set null;

create function workflow_private.guard_report_claim() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.cluster_id is not null and (tg_op='INSERT' or new.cluster_id is distinct from old.cluster_id)
    and exists(select 1 from public.clusters where id=new.cluster_id and status::text in ('scheduled','in_progress','deferred')) then
    raise exception 'Cannot add reports to an active or blocked cluster';
  end if;
  if tg_op='UPDATE' then
    if old.cleanup_task_id is not null and
      (new.cleanup_task_id is distinct from old.cleanup_task_id or new.cluster_id is distinct from old.cluster_id)
      and exists(select 1 from public.cleanup_tasks where id=old.cleanup_task_id and status::text not in ('completed','cancelled')) then
      raise exception 'Active report claim cannot be replaced or regrouped';
    end if;
    if old.cluster_id is not null and new.cluster_id is distinct from old.cluster_id
      and exists(select 1 from public.clusters where id=old.cluster_id and status::text in ('scheduled','in_progress','deferred')) then
      raise exception 'Active or blocked cluster membership cannot be changed';
    end if;
  end if;
  if new.cleanup_task_id is not null and (tg_op='INSERT' or new.cleanup_task_id is distinct from old.cleanup_task_id) then
    if exists(select 1 from public.dispatch_access_blocks where cleared_at is null and
      (report_id=new.id or cluster_id=new.cluster_id)) then raise exception 'dispatch_blocked'; end if;
  end if;
  return new;
end; $$;
create trigger workflow_report_claim_guard before insert or update on public.reports
  for each row execute function workflow_private.guard_report_claim();

create function workflow_private.guard_cluster_block() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status::text in ('new','unresolved','prioritized','queued','monitoring','scheduled','in_progress')
    and exists(select 1 from public.dispatch_access_blocks where cluster_id=new.id and cleared_at is null) then
    raise exception 'Blocked cluster requires officer clearance';
  end if;
  return new;
end; $$;
create trigger workflow_cluster_block_guard before update of status on public.clusters
  for each row execute function workflow_private.guard_cluster_block();

create function workflow_private.release_finished_task() returns trigger
language plpgsql security definer set search_path='' as $$
declare target uuid; failure text;
begin
  if new.status::text not in ('completed','cancelled') or old.status is not distinct from new.status then return new; end if;
  failure:=coalesce(new.failure_class,'unclassified');
  if new.status::text='cancelled' then
    if failure<>'transient' then
      for target in select distinct cluster_id from public.reports where cleanup_task_id=new.id and cluster_id is not null loop
        insert into public.dispatch_access_blocks(cluster_id,task_id,reason,failure_class,blocked_by)
        values(target,new.id,coalesce(nullif(btrim(new.failure_reason),''),'Unclassified task cancellation'),failure,new.completed_by)
        on conflict do nothing;
        update public.clusters set status='deferred' where id=target;
      end loop;
      insert into public.dispatch_access_blocks(report_id,task_id,reason,failure_class,blocked_by)
        select id,new.id,coalesce(nullif(btrim(new.failure_reason),''),'Unclassified task cancellation'),failure,new.completed_by
        from public.reports where cleanup_task_id=new.id and cluster_id is null
          and status::text not in ('resolved','completed','closed','rejected')
        on conflict do nothing;
    else
      update public.clusters set status='prioritized' where id in (select cluster_id from public.reports where cleanup_task_id=new.id);
    end if;
  else
    for target in select distinct cluster_id from public.reports where cleanup_task_id=new.id and cluster_id is not null loop
      update public.clusters set status=(case when exists(select 1 from public.reports where cluster_id=target
        and status::text not in ('resolved','completed','closed','rejected')) then 'prioritized' else 'resolved' end)::public.cluster_status where id=target;
    end loop;
  end if;
  update public.reports set cleanup_task_id=null,
    status=(case when status::text='in_progress' then 'unresolved' else status::text end)::public.report_status,updated_at=now()
    where cleanup_task_id=new.id;
  insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
    values('TASK_REPORTS_RELEASED','TASK',new.id::text,coalesce(new.completed_by::text,'system'),
      jsonb_build_object('status',new.status,'failure_class',new.failure_class,'reason',new.failure_reason));
  return new;
end; $$;
create trigger workflow_task_release after update of status on public.cleanup_tasks
  for each row execute function workflow_private.release_finished_task();

create function workflow_private.can_execute_task(actor uuid, task public.cleanup_tasks) returns boolean
language sql stable set search_path='' as $$
  select exists(select 1 from public.profiles p where p.id=actor and
    (p.role::text in ('admin','officer') or (p.role::text='field_crew' and
      task.route_status='ready' and actor=any(coalesce(task.assigned_crew_ids,'{}'::uuid[])))));
$$;

create function public.submit_task_outcome(task_id uuid, actor uuid, outcome text, notes text,
  classification text default null, expected_version bigint default null, operation_id text default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare task public.cleanup_tasks; cleaned boolean; terminal boolean; target_status public.cleanup_task_status;
begin
  select * into task from public.cleanup_tasks where id=task_id for update;
  if not found then raise exception 'Task not found' using errcode='P0002'; end if;
  if not workflow_private.can_execute_task(actor,task) then raise exception 'Task access denied' using errcode='42501'; end if;
  if outcome not in ('completed','cleanup_completed','report_incorrect','issue_not_found','already_resolved','partially_completed',
    'unable_to_complete','issue_still_exists','requires_follow_up','needs_another_inspection','escalated','requires_institutional_action','cancelled') then
    raise exception 'Unsupported task outcome' using errcode='22023';
  end if;
  if task.status::text in ('completed','cancelled') then
    if task.completion_result=outcome or (task.status::text='completed' and outcome='completed') then
      return jsonb_build_object('status','duplicate','server_record',to_jsonb(task));
    end if;
    return jsonb_build_object('status','conflict','server_record',to_jsonb(task),'error_message','Task already has a terminal outcome');
  end if;
  if expected_version is not null and expected_version<>task.fc_version then
    return jsonb_build_object('status','conflict','server_record',to_jsonb(task),'error_message','Task version changed');
  end if;
  cleaned:=outcome='cleanup_completed' or (outcome='completed' and task.task_type::text in ('Cleanup','Sweeper'));
  terminal:=outcome in ('completed','cleanup_completed','report_incorrect','issue_not_found','already_resolved');
  if not terminal and outcome<>'partially_completed' and (classification is null or classification not in ('transient','site','safety','unclassified') or nullif(btrim(notes),'') is null) then
    raise exception 'Failure classification and notes are required' using errcode='22023';
  end if;
  if cleaned then
    update public.reports set status='resolved',lgu_resolved_at=now(),updated_at=now() where cleanup_task_id=task_id
      and status::text not in ('resolved','completed','closed','rejected');
  elsif outcome in ('report_incorrect','issue_not_found') then
    update public.reports set status='closed',updated_at=now() where cleanup_task_id=task_id
      and status::text not in ('resolved','completed','closed','rejected');
  elsif outcome='already_resolved' and exists(select 1 from public.reports where cleanup_task_id=task_id
    and status::text not in ('resolved','completed','closed','rejected')) then
    -- A clean-looking site is an observation, not proof this report was cleaned by this crew.
    raise exception 'Already-resolved observation requires verification while reports remain open' using errcode='22023';
  end if;
  target_status:=(case when terminal then 'completed' when outcome='partially_completed' then 'partially_completed' else 'cancelled' end)::public.cleanup_task_status;
  update public.cleanup_tasks set status=target_status,completion_result=outcome,completion_notes=submit_task_outcome.notes,completed_by=actor,
    failure_class=case when terminal or outcome='partially_completed' then null else classification end,
    failure_reason=case when terminal or outcome='partially_completed' then null else submit_task_outcome.notes end,
    completed_at=case when target_status::text in ('completed','cancelled') then now() else null end,
    completion_operation_id=operation_id,fc_version=fc_version+1
    where id=task_id returning * into task;
  return jsonb_build_object('status','success','server_record',to_jsonb(task));
end; $$;

create function public.clear_dispatch_block(block_id uuid, actor uuid, notes text) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare block public.dispatch_access_blocks;
begin
  perform workflow_private.require_desk_actor(actor);
  if nullif(btrim(notes),'') is null then raise exception 'Clearance notes required' using errcode='22023'; end if;
  select * into block from public.dispatch_access_blocks where id=block_id for update;
  if not found then raise exception 'Block not found' using errcode='P0002'; end if;
  if block.cleared_at is null then
    update public.dispatch_access_blocks set cleared_at=now(),cleared_by=actor,clearance_notes=notes where id=block_id returning * into block;
    if block.cluster_id is not null then update public.clusters set status='prioritized' where id=block.cluster_id; end if;
    insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
      values('DISPATCH_BLOCK_CLEARED','BLOCK',block_id::text,actor::text,jsonb_build_object('notes',notes));
  end if;
  return to_jsonb(block);
end; $$;

create function public.expire_unpublished_dispatch_claims() returns jsonb
language plpgsql security invoker set search_path='' as $$
declare task public.cleanup_tasks; expired integer:=0; escalated integer:=0;
begin
  for task in select * from public.cleanup_tasks where route_status='needs_replan'
    and routing_deadline_at<=now()+interval '15 minutes' order by id for update skip locked loop
    if task.routing_deadline_at<=now() and task.assigned_at is null and coalesce(cardinality(task.assigned_crew_ids),0)=0 and task.status::text in ('created','pending') then
      update public.cleanup_tasks set route_status='expired',status='cancelled',failure_class='transient',
        failure_reason='Unpublished route planning expired',completion_result='routing_expired' where id=task.id;
      expired:=expired+1;
    elsif task.routing_escalated_at is null then
      update public.cleanup_tasks set routing_escalated_at=now() where id=task.id;
      insert into public.sweeper_audit_log(event_type,entity_type,entity_id,user_id,event_data)
        values('ROUTING_ESCALATION','TASK',task.id::text,'system',jsonb_build_object('routing_deadline_at',task.routing_deadline_at,'assigned_at',task.assigned_at));
      escalated:=escalated+1;
    end if;
  end loop;
  return jsonb_build_object('expiredCount',expired,'escalatedCount',escalated);
end; $$;

create or replace function public.dbscan_reports(p_eps double precision,p_minpoints integer)
returns table(id uuid,issue_type text,location extensions.geometry,is_outlier boolean,cluster_id integer)
language plpgsql security invoker set search_path='' as $$
begin
  if p_eps<=0 or p_eps>10000 or p_minpoints<2 or p_minpoints>100 then raise exception 'Invalid clustering parameters'; end if;
  return query select r.id,r.issue_type::text,r.location::extensions.geometry,false,
    extensions.st_clusterdbscan(extensions.st_transform(r.location::extensions.geometry,32651),eps:=p_eps,minpoints:=p_minpoints) over()
    from public.reports r where r.status::text='unresolved' and r.cluster_id is null and r.cleanup_task_id is null
      and r.lifecycle_state='fresh'
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null);
end; $$;

create or replace function public.upsert_cluster_for_reports_v2(p_report_ids uuid[],p_issue_type text,p_severity text,p_radius_meters double precision)
returns uuid language plpgsql security invoker set search_path='' as $$
declare locked_ids uuid[]; centroid extensions.geometry; cluster uuid;
begin
  if cardinality(p_report_ids)<2 or cardinality(p_report_ids)<>(select count(distinct x) from unnest(p_report_ids) x) then raise exception 'Distinct fresh reports required'; end if;
  select array_agg(id order by id) into locked_ids from (
    select r.id from public.reports r where id=any(p_report_ids) and r.status::text='unresolved'
      and cluster_id is null and cleanup_task_id is null and lifecycle_state='fresh'
      and not exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null)
    order by id for update skip locked
  ) r;
  if coalesce(cardinality(locked_ids),0)<>cardinality(p_report_ids) then raise exception 'Clustering snapshot is stale'; end if;
  select extensions.st_centroid(extensions.st_collect(location::extensions.geometry)) into centroid from public.reports where id=any(locked_ids);
  insert into public.clusters(center,issue_type,severity,status,radius_meters,report_count)
    values(centroid,p_issue_type::public.report_issue_type,p_severity::public.cluster_severity,'new',p_radius_meters,cardinality(locked_ids)) returning id into cluster;
  update public.reports set cluster_id=cluster,updated_at=now() where id=any(locked_ids);
  return cluster;
end; $$;

revoke all on function public.submit_task_outcome(uuid,uuid,text,text,text,bigint,text),public.clear_dispatch_block(uuid,uuid,text),public.expire_unpublished_dispatch_claims(),public.dbscan_reports(double precision,integer),public.upsert_cluster_for_reports_v2(uuid[],text,text,double precision) from public,anon,authenticated;
grant execute on function public.submit_task_outcome(uuid,uuid,text,text,text,bigint,text),public.clear_dispatch_block(uuid,uuid,text),public.expire_unpublished_dispatch_claims(),public.dbscan_reports(double precision,integer),public.upsert_cluster_for_reports_v2(uuid[],text,text,double precision) to service_role;
revoke all on all functions in schema workflow_private from public,anon,authenticated;
grant execute on all functions in schema workflow_private to service_role;
commit;
