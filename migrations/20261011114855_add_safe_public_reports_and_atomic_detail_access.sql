SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='30s';
CREATE ROLE ecopin_public_map_reader NOLOGIN NOINHERIT NOBYPASSRLS;
GRANT ecopin_public_map_reader TO postgres;
GRANT USAGE ON SCHEMA public,extensions TO ecopin_public_map_reader;
GRANT SELECT (id,title,description,issue_type,status,cluster_id,created_at,updated_at,stage,is_overdue,severity_score,severity_level,lifecycle_state,breached_at,validation_status,location,on_private_property,property_owner_consent_status)
ON public.reports TO ecopin_public_map_reader;
CREATE POLICY public_map_reader_approved_consent ON public.reports FOR SELECT TO ecopin_public_map_reader
USING (validation_status='approved' AND status<>'rejected' AND
  (on_private_property IS FALSE OR (on_private_property IS TRUE AND property_owner_consent_status='obtained')));
CREATE VIEW public.public_reports WITH (security_barrier=true,security_invoker=false) AS
SELECT id,title,description,issue_type,status,cluster_id,created_at,updated_at,stage,is_overdue,
 severity_score,severity_level,lifecycle_state,breached_at,validation_status,
 extensions.st_asgeojson(CASE WHEN on_private_property THEN
   extensions.st_setsrid(extensions.st_makepoint(
    round(extensions.st_x(location::extensions.geometry)::numeric,3)::double precision,
    round(extensions.st_y(location::extensions.geometry)::numeric,3)::double precision),4326)
 ELSE location::extensions.geometry END,9,0)::jsonb AS location,
 CASE WHEN on_private_property THEN round(extensions.st_y(location::extensions.geometry)::numeric,3)::double precision ELSE extensions.st_y(location::extensions.geometry) END AS latitude,
 CASE WHEN on_private_property THEN round(extensions.st_x(location::extensions.geometry)::numeric,3)::double precision ELSE extensions.st_x(location::extensions.geometry) END AS longitude,
 CASE WHEN on_private_property THEN 'approximate'::text ELSE 'exact'::text END AS location_precision
FROM public.reports
WHERE validation_status='approved' AND status<>'rejected'
 AND (on_private_property IS FALSE OR (on_private_property IS TRUE AND property_owner_consent_status='obtained'));
GRANT CREATE ON SCHEMA public TO ecopin_public_map_reader;
ALTER VIEW public.public_reports OWNER TO ecopin_public_map_reader;
REVOKE CREATE ON SCHEMA public FROM ecopin_public_map_reader;
REVOKE ALL ON public.public_reports FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.public_reports TO anon,authenticated,service_role;

SET LOCAL lock_timeout='2s';
CREATE FUNCTION public.read_authorized_report_detail(actor uuid, report_id uuid)
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
    AND task.status::text IN ('created','pending','in_progress','partially_completed')
    AND actor=ANY(coalesce(task.assigned_crew_ids,'{}'::uuid[]))
  ))
 )
);
$$;
REVOKE ALL ON FUNCTION public.read_authorized_report_detail(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_authorized_report_detail(uuid,uuid) TO service_role;
