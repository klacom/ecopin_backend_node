begin;

create function public.save_mixed_dispatch_draft(actor uuid, job_id uuid, worker_id uuid,
  settings jsonb, items jsonb, proposal jsonb, capacity jsonb, rejected jsonb, diagnostics jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare plan public.dispatch_plans; job public.plan_generation_jobs; item jsonb; ids uuid[]; seen uuid[]:='{}';
begin
  perform workflow_private.require_desk_actor(actor);
  select * into job from public.plan_generation_jobs where id=job_id for update;
  if not found or job.requested_by<>actor or job.mode<>'mixed' or job.status<>'running'
    or job.worker_token is distinct from worker_id or job.lease_until<now() then
    raise exception 'Planning job lease expired';
  end if;
  if jsonb_typeof(settings) is distinct from 'object' or jsonb_typeof(items) is distinct from 'array'
     or jsonb_array_length(items)>400 or jsonb_typeof(proposal) is distinct from 'object'
     or jsonb_typeof(proposal->'routes') is distinct from 'array'
     or jsonb_typeof(rejected) is distinct from 'array' then raise exception 'Invalid Mixed draft'; end if;
  insert into public.dispatch_plans(created_by,mode,settings_snapshot,total_crews_available,total_capacity_minutes,
    capacity_breakdown,route_proposal,rejected_bundles,solver_diagnostics,planning_as_of,generation_job_id,status)
  values(actor,'mixed',settings,coalesce((capacity->>'availableCrews')::integer,0),
    coalesce((capacity->>'totalMinutes')::integer,0),coalesce(capacity,'{}'::jsonb),proposal,rejected,
    coalesce(diagnostics,'{}'::jsonb),now(),job_id,'draft') returning * into plan;
  for item in select value from jsonb_array_elements(items) loop
    select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(item->'report_ids');
    if cardinality(ids)=0 or cardinality(ids)<>(select count(distinct x) from unnest(ids) x)
      or ids && seen then raise exception 'Duplicate or empty report snapshot'; end if;
    seen:=seen||ids;
    if item->>'item_type' not in ('cluster','report','bundled_report')
      or (item->>'is_selected')::boolean and (item->>'planned_crew_id') is null then
      raise exception 'Invalid Mixed item'; end if;
    if item->>'item_type'='bundled_report' and ids<>array[(item->>'report_id')::uuid] then
      raise exception 'Satellite snapshot must match report target'; end if;
    insert into public.dispatch_plan_items(dispatch_plan_id,cluster_id,cluster_ids,report_id,anchor_cluster_id,
      report_ids,item_type,group_key,planned_crew_id,is_selected,reason,estimated_duration_minutes,
      estimated_work_minutes,priority_score,crew_snapshot,bundle_order,detour_minutes,
      estimated_volume_m3,estimated_weight_kg,load_snapshot)
    values(plan.id,(item->>'cluster_id')::uuid,
      coalesce((select array_agg(value::uuid) from jsonb_array_elements_text(coalesce(item->'cluster_ids','[]'::jsonb))),'{}'::uuid[]),
      (item->>'report_id')::uuid,(item->>'anchor_cluster_id')::uuid,ids,item->>'item_type',item->>'group_key',
      (item->>'planned_crew_id')::uuid,(item->>'is_selected')::boolean,item->>'reason',
      (item->>'estimated_duration_minutes')::integer,(item->>'estimated_work_minutes')::integer,
      (item->>'priority_score')::numeric,coalesce(item->'crew_snapshot','{}'::jsonb),
      (item->>'bundle_order')::smallint,(item->>'detour_minutes')::numeric,
      (item->>'estimated_volume_m3')::numeric,(item->>'estimated_weight_kg')::numeric,item->'load_snapshot');
  end loop;
  return to_jsonb(plan);
end; $$;

revoke all on function public.save_mixed_dispatch_draft(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb)
  from public,anon,authenticated;
grant execute on function public.save_mixed_dispatch_draft(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb)
  to service_role;

commit;
