SET LOCAL lock_timeout='2s';
CREATE FUNCTION public.read_authorized_cleanup_tasks(
  actor uuid, p_task_id uuid DEFAULT NULL, p_cluster_id uuid DEFAULT NULL,
  p_assigned_only boolean DEFAULT false, p_limit integer DEFAULT 201, p_offset integer DEFAULT 0
) RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=''
AS $$
WITH viewer AS (
 SELECT id,role::text AS role FROM public.profiles WHERE id=actor
), allowed AS (
 SELECT task.*,viewer.role AS viewer_role,
   (viewer.role IN ('officer','admin') OR
    (viewer.role='field_crew' AND task.route_status='ready'
      AND task.status::text IN ('created','pending','in_progress','partially_completed')
      AND actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])))) AS full_access
 FROM public.cleanup_tasks task CROSS JOIN viewer
 WHERE (p_task_id IS NULL OR task.id=p_task_id)
   AND (p_cluster_id IS NULL OR task.cluster_id=p_cluster_id)
   AND (NOT p_assigned_only OR actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])))
   AND (
    viewer.role IN ('officer','admin')
    OR (viewer.role='field_crew' AND actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[])))
    OR (viewer.role='citizen' AND p_cluster_id IS NOT NULL AND EXISTS(
     SELECT 1 FROM public.reports r
     WHERE (r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
       AND (r.user_id=actor OR (r.validation_status='approved' AND r.status<>'rejected'
        AND (r.on_private_property IS FALSE OR
          (r.on_private_property IS TRUE AND r.property_owner_consent_status='obtained'))))
    ))
   )
   AND p_limit BETWEEN 1 AND 501 AND p_offset BETWEEN 0 AND 250000
 ORDER BY task.created_at DESC NULLS LAST,task.id DESC
 LIMIT greatest(1,least(coalesce(p_limit,1),501))
 OFFSET greatest(0,least(coalesce(p_offset,0),250000))
), projected AS (
 SELECT task.created_at,task.id,
 CASE WHEN task.full_access THEN
   (to_jsonb(task)-'viewer_role'-'full_access') || jsonb_build_object(
    'clusters',CASE WHEN task.viewer_role IN ('officer','admin') THEN
       (SELECT to_jsonb(c) FROM public.clusters c WHERE c.id=task.cluster_id)
     ELSE jsonb_build_object('id',task.cluster_id) END,
    'reports',coalesce((SELECT jsonb_agg(jsonb_build_object(
     'id',r.id,'title',r.title,'description',r.description,'issue_type',r.issue_type,
     'location',r.location,'status',r.status,'report_claim_generation',r.report_claim_generation)
     ORDER BY r.id) FROM public.reports r WHERE r.cleanup_task_id=task.id),'[]'::jsonb),
    'report_claim_generations',coalesce((SELECT jsonb_object_agg(r.id::text,r.report_claim_generation)
     FROM public.reports r WHERE r.cleanup_task_id=task.id),'{}'::jsonb),
    'access_level','detail')
 ELSE jsonb_build_object(
    'id',task.id,'cluster_id',task.cluster_id,'title','Cleanup progress',
    'status',task.status,'created_at',task.created_at,'completed_at',task.completed_at,
    'is_custom',task.is_custom,'access_level','summary',
    'before_photo_url',CASE WHEN NOT EXISTS(SELECT 1
      FROM unnest(coalesce(task.report_ids,'{}'::uuid[])) AS membership(report_id)
      LEFT JOIN public.reports member_report ON member_report.id=membership.report_id
      WHERE member_report.id IS NULL)
      AND EXISTS(SELECT 1 FROM public.reports r
      WHERE r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
      AND NOT EXISTS(SELECT 1 FROM public.reports r
       WHERE (r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
        AND NOT coalesce(r.user_id=actor OR
          (r.validation_status='approved' AND r.status<>'rejected' AND r.on_private_property IS FALSE),false))
      THEN task.before_photo_url ELSE NULL END,
    'after_photo_url',CASE WHEN NOT EXISTS(SELECT 1
      FROM unnest(coalesce(task.report_ids,'{}'::uuid[])) AS membership(report_id)
      LEFT JOIN public.reports member_report ON member_report.id=membership.report_id
      WHERE member_report.id IS NULL)
      AND EXISTS(SELECT 1 FROM public.reports r
      WHERE r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
      AND NOT EXISTS(SELECT 1 FROM public.reports r
       WHERE (r.cleanup_task_id=task.id OR r.id=ANY(coalesce(task.report_ids,'{}'::uuid[])))
        AND NOT coalesce(r.user_id=actor OR
          (r.validation_status='approved' AND r.status<>'rejected' AND r.on_private_property IS FALSE),false))
      THEN task.after_photo_url ELSE NULL END)
 END AS data FROM allowed task
)
SELECT coalesce(jsonb_agg(data ORDER BY created_at DESC NULLS LAST,id DESC),'[]'::jsonb)
FROM projected;
$$;
REVOKE ALL ON FUNCTION public.read_authorized_cleanup_tasks(uuid,uuid,uuid,boolean,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_authorized_cleanup_tasks(uuid,uuid,uuid,boolean,integer,integer) TO service_role;

