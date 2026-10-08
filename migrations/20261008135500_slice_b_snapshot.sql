begin;

create function public.mixed_planning_snapshot()
returns jsonb language sql stable security invoker set search_path='' as $$
with anchors as (
  select c.id, c.priority_score, c.estimated_effort_minutes, c.recommended_task_type,
    c.created_at, extensions.st_y(c.center) as lat, extensions.st_x(c.center) as lng,
    (select case when count(*)=count(w.estimated_volume_m3) then sum(w.estimated_volume_m3) end from public.reports r left join public.work_time_configuration w on w.report_type=r.issue_type::text
      where r.cluster_id=c.id and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')) as estimated_volume_m3,
    (select case when count(*)=count(w.estimated_weight_kg) then sum(w.estimated_weight_kg) end from public.reports r left join public.work_time_configuration w on w.report_type=r.issue_type::text
      where r.cluster_id=c.id and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')) as estimated_weight_kg,
    array(select r.id from public.reports r where r.cluster_id=c.id
      and r.cleanup_task_id is null and r.status::text not in ('resolved','completed','closed','rejected')
      order by r.id) as report_ids
  from public.clusters c
  where c.status::text in ('new','unresolved','prioritized','queued','monitoring')
    and c.is_outlier is not true
    and not exists(select 1 from public.dispatch_access_blocks b where b.cluster_id=c.id and b.cleared_at is null)
    and not exists(select 1 from public.reports r join public.dispatch_access_blocks b on b.report_id=r.id
      where r.cluster_id=c.id and b.cleared_at is null)
  order by c.priority_score desc nulls last,c.id limit 200
),
satellites as (
  select r.id, r.issue_type::text, r.lifecycle_state::text, r.severity_score, r.urgency_score,
    r.created_at, r.sla_started_at, r.deadline_at,
    extensions.st_y(r.location::extensions.geometry) as lat,
    extensions.st_x(r.location::extensions.geometry) as lng,
    w.work_time_minutes, w.estimated_volume_m3, w.estimated_weight_kg,
    exists(select 1 from public.dispatch_access_blocks b where b.report_id=r.id and b.cleared_at is null) as blocked
  from public.reports r left join public.work_time_configuration w on w.report_type=r.issue_type::text
  where r.status::text='unresolved' and r.cluster_id is null and r.cleanup_task_id is null
    and r.lifecycle_state in ('maturing','sla_breached') and r.location is not null
  order by r.deadline_at nulls last,r.id limit 200
)
select jsonb_build_object(
  'anchors',coalesce((select jsonb_agg(to_jsonb(a)) from anchors a where cardinality(a.report_ids)>0),'[]'::jsonb),
  'satellites',coalesce((select jsonb_agg(to_jsonb(s)) from satellites s),'[]'::jsonb)
);
$$;

revoke all on function public.mixed_planning_snapshot() from public,anon,authenticated;
grant execute on function public.mixed_planning_snapshot() to service_role;

commit;
