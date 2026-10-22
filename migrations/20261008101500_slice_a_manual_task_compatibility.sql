-- Preserve the officer custom-task contract while claiming reports atomically.
begin;

create or replace function public.create_manual_cleanup_task(
  actor uuid, selected_report_ids uuid[], task_title text,
  task_description text default null, crew_member_ids uuid[] default '{}'::uuid[],
  task_priority text default null
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  claimed_ids uuid[];
  linked_clusters uuid[];
  first_location extensions.geography;
  task public.cleanup_tasks;
  member_count integer;
begin
  perform workflow_private.require_desk_actor(actor);
  if nullif(btrim(task_title),'') is null then
    raise exception 'Task title is required' using errcode='22023';
  end if;
  if selected_report_ids is null or cardinality(selected_report_ids)=0 or
     array_position(selected_report_ids,null) is not null or
     cardinality(selected_report_ids)<>(select count(distinct id) from unnest(selected_report_ids) id) then
    raise exception 'Distinct report IDs are required' using errcode='22023';
  end if;
  if task_priority is not null and task_priority not in ('low','medium','high') then
    raise exception 'Invalid priority' using errcode='22023';
  end if;
  if crew_member_ids is null or array_position(crew_member_ids,null) is not null or
     cardinality(crew_member_ids)<>(select count(distinct id) from unnest(crew_member_ids) id) then
    raise exception 'Distinct crew member IDs are required' using errcode='22023';
  end if;
  select count(*) into member_count from public.profiles p
    where p.id=any(crew_member_ids) and p.role::text='field_crew';
  if member_count<>cardinality(crew_member_ids) then
    raise exception 'All assignees must be field crew members' using errcode='22023';
  end if;

  select coalesce(array_agg(r.id order by r.id),'{}'::uuid[]) into claimed_ids from (
    select id from public.reports where id=any(selected_report_ids)
      and cleanup_task_id is null
      and status::text not in ('resolved','completed','closed','rejected')
      and validation_status::text is distinct from 'manual_review'
      and not exists(select 1 from public.dispatch_access_blocks b
        where b.cleared_at is null and
          (b.report_id=reports.id or b.cluster_id=reports.cluster_id))
    order by id for update skip locked
  ) r;
  if cardinality(claimed_ids)<>cardinality(selected_report_ids) then
    return jsonb_build_object('status','conflict','reason','stale_or_blocked_report');
  end if;
  select coalesce(array_agg(distinct cluster_id) filter(where cluster_id is not null),'{}'::uuid[]),
    (select location from public.reports where id=selected_report_ids[1])
    into linked_clusters,first_location from public.reports where id=any(claimed_ids);

  insert into public.cleanup_tasks(
    cluster_id,cluster_ids,report_ids,report_sequence,title,description,status,
    is_custom,priority,created_by,assigned_crew_ids,assigned_at,assigned_by,
    last_assigned_at,route_status,task_type,location
  ) values (
    case when cardinality(linked_clusters)=1 and
      (select count(*) from public.reports where id=any(claimed_ids) and cluster_id is null)=0
      then linked_clusters[1] else null end,
    linked_clusters,claimed_ids,selected_report_ids,task_title,task_description,
    (case when cardinality(crew_member_ids)>0 then 'pending' else 'created' end)::public.cleanup_task_status,
    true,task_priority,actor,crew_member_ids,
    case when cardinality(crew_member_ids)>0 then now() else null end,
    case when cardinality(crew_member_ids)>0 then actor else null end,
    case when cardinality(crew_member_ids)>0 then now() else null end,
    'ready','Cleanup',first_location
  ) returning * into task;

  update public.reports set cleanup_task_id=task.id,updated_at=now()
    where id=any(claimed_ids) and cleanup_task_id is null;
  if not found or (select count(*) from public.reports where cleanup_task_id=task.id)<>cardinality(claimed_ids) then
    raise exception 'Report claim changed during manual task creation' using errcode='40001';
  end if;
  return jsonb_build_object('status','created','task',to_jsonb(task));
end; $$;

revoke all on function public.create_manual_cleanup_task(uuid,uuid[],text,text,uuid[],text)
  from public,anon,authenticated;
grant execute on function public.create_manual_cleanup_task(uuid,uuid[],text,text,uuid[],text)
  to service_role;
commit;
