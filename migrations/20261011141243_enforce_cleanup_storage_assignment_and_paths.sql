-- Restrict cleanup uploads to existing entity paths and current authorization.
CREATE SCHEMA storage_authority;
REVOKE ALL ON SCHEMA storage_authority FROM PUBLIC;
GRANT USAGE ON SCHEMA storage_authority TO authenticated;

CREATE FUNCTION storage_authority.can_upload_cleanup_object(bucket text, object_path text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE actor uuid := auth.uid(); actor_role text; entity uuid;
BEGIN
  IF actor IS NULL OR bucket IS NULL OR bucket NOT IN ('Cleanup Task Photos','Report Cleanup')
     OR object_path IS NULL OR length(object_path)>180
     OR object_path !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/(before|after)/[a-zA-Z0-9._-]{1,128}$'
     OR split_part(object_path,'/',3) IN ('.','..') THEN RETURN false; END IF;
  SELECT p.role::text INTO actor_role FROM public.profiles p WHERE p.id=actor;
  IF actor_role IS NULL OR actor_role NOT IN ('field_crew','officer','admin') THEN RETURN false; END IF;
  entity := split_part(object_path,'/',1)::uuid;
  IF bucket='Cleanup Task Photos' THEN
    RETURN EXISTS (SELECT 1 FROM public.cleanup_tasks t WHERE t.id=entity
      AND (actor_role IN ('officer','admin') OR
        (actor=ANY(t.assigned_crew_ids) AND t.route_status='ready'
         AND t.status::text IN ('created','pending','in_progress','partially_completed'))));
  END IF;
  RETURN EXISTS (SELECT 1 FROM public.reports r JOIN public.cleanup_tasks t ON t.id=r.cleanup_task_id
    WHERE r.id=entity AND (actor_role IN ('officer','admin') OR
      (actor=ANY(t.assigned_crew_ids) AND t.route_status='ready'
       AND t.status::text IN ('created','pending','in_progress','partially_completed'))));
END;
$function$;
REVOKE ALL ON FUNCTION storage_authority.can_upload_cleanup_object(text,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION storage_authority.can_upload_cleanup_object(text,text) TO authenticated;
ALTER POLICY "Authenticated users can upload Cleanup Task Photos" ON storage.objects
  WITH CHECK (bucket_id='Cleanup Task Photos' AND storage_authority.can_upload_cleanup_object(bucket_id,name));
ALTER POLICY "Authenticated users can upload Report Cleanup" ON storage.objects
  WITH CHECK (bucket_id='Report Cleanup' AND storage_authority.can_upload_cleanup_object(bucket_id,name));
