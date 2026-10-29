BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.get_report_lifecycle_summary() RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 WITH classified AS MATERIALIZED (
  SELECT coalesce(status::text,'(missing)') AS raw_status,
   CASE
    WHEN status IS NULL OR status::text NOT IN ('unresolved','pending','submitted','verified','assigned','in_progress','resolved','closed','completed','waiting_for_feedback','pending_owner_consent','rejected') THEN 'uncategorized'
    WHEN status::text IN ('resolved','closed','completed','waiting_for_feedback') THEN 'resolved'
    WHEN status::text='rejected' OR validation_status::text='rejected' THEN 'rejected'
    WHEN status::text='in_progress' OR stage::text='in_progress' THEN 'in_progress'
    WHEN cleanup_task_id IS NOT NULL OR status::text='assigned' OR stage::text='assigned' THEN 'assigned'
    WHEN validation_status::text IN ('approved','validated') OR status::text='verified' OR stage::text='acknowledged' THEN 'verified'
    ELSE 'submitted'
   END AS bucket
  FROM public.reports
 ) SELECT jsonb_build_object(
  'total',count(*),'snapshotAt',statement_timestamp(),'classificationVersion','pdt25-v1',
  'byLifecycle',jsonb_build_object(
   'submitted',count(*) FILTER(WHERE bucket='submitted'),
   'verified',count(*) FILTER(WHERE bucket='verified'),
   'assigned',count(*) FILTER(WHERE bucket='assigned'),
   'in_progress',count(*) FILTER(WHERE bucket='in_progress'),
   'resolved',count(*) FILTER(WHERE bucket='resolved'),
   'rejected',count(*) FILTER(WHERE bucket='rejected'),
   'uncategorized',count(*) FILTER(WHERE bucket='uncategorized')),
  'byStatus',coalesce((SELECT jsonb_object_agg(raw_status,n) FROM (SELECT raw_status,count(*) AS n FROM classified GROUP BY raw_status) s),'{}'::jsonb),
  'uncategorizedByStatus',coalesce((SELECT jsonb_object_agg(raw_status,n) FROM (SELECT raw_status,count(*) AS n FROM classified WHERE bucket='uncategorized' GROUP BY raw_status) s),'{}'::jsonb)
 ) FROM classified;
$$;
REVOKE ALL ON FUNCTION public.get_report_lifecycle_summary() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_report_lifecycle_summary() TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
