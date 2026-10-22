begin;
CREATE OR REPLACE FUNCTION public.read_authorized_report_detail(actor uuid, report_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=''
AS $$
SELECT to_jsonb(r) || jsonb_build_object('profiles',
 jsonb_build_object('id',owner.id,'full_name',owner.full_name,'data_consent',owner.data_consent))
FROM public.reports r
LEFT JOIN public.profiles owner ON owner.id=r.user_id
WHERE r.id=report_id AND EXISTS(
 SELECT 1 FROM public.profiles viewer
 WHERE viewer.id=actor AND (
  viewer.id=r.user_id OR viewer.role::text IN ('officer','admin') OR
  (viewer.role::text='field_crew' AND EXISTS(
   SELECT 1 FROM public.cleanup_tasks task
   WHERE task.id=r.cleanup_task_id AND task.route_status='ready'
    AND task.status::text IN ('created','pending','assigned','en_route','in_progress','partially_completed')
    AND (
      actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[]))
      OR (task.assigned_field_crew_id IS NOT NULL AND EXISTS(
        SELECT 1 FROM public.field_crews c
        WHERE c.id=task.assigned_field_crew_id
          AND (c.team_lead_profile_id=actor OR actor=ANY(coalesce(c.member_profile_ids,'{}'::uuid[])))
      ))
    )
  ))
 )
);
$$;
REVOKE ALL ON FUNCTION public.read_authorized_report_detail(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_authorized_report_detail(uuid,uuid) TO service_role;
commit;
