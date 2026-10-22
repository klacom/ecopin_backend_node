BEGIN;
SET LOCAL lock_timeout='2s';
CREATE OR REPLACE FUNCTION storage_authority.can_read_cleanup_object(bucket text, object_path text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  actor uuid := auth.uid();
  actor_role text;
  entity uuid;
BEGIN
  IF actor IS NULL OR bucket IS NULL OR bucket NOT IN ('Cleanup Task Photos', 'Report Cleanup')
     OR object_path IS NULL OR length(object_path) > 180
     OR object_path !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/(before|after)/[a-zA-Z0-9._-]{1,128}$'
     OR split_part(object_path, '/', 3) IN ('.', '..') THEN
    RETURN false;
  END IF;

  SELECT p.role::text INTO actor_role FROM public.profiles p WHERE p.id = actor;
  IF actor_role IS NULL THEN RETURN false; END IF;
  IF actor_role IN ('officer', 'admin') THEN RETURN true; END IF;

  entity := split_part(object_path, '/', 1)::uuid;
  IF bucket = 'Cleanup Task Photos' THEN
    IF actor_role = 'field_crew' THEN
      RETURN EXISTS (
        SELECT 1 FROM public.cleanup_tasks t
        WHERE t.id = entity
          AND actor = ANY(coalesce(t.assigned_crew_ids, '{}'::uuid[]))
          AND t.route_status='ready'
          AND t.status::text IN ('created','pending','in_progress','partially_completed')
      );
    END IF;
    IF actor_role = 'citizen' THEN
      RETURN EXISTS (
        SELECT 1 FROM public.reports r
        WHERE r.cleanup_task_id = entity AND r.user_id = actor
          AND NOT EXISTS (SELECT 1 FROM public.reports other
            WHERE other.cleanup_task_id=entity AND other.user_id IS DISTINCT FROM actor)
      );
    END IF;
    RETURN false;
  END IF;

  IF bucket = 'Report Cleanup' THEN
    IF actor_role = 'field_crew' THEN
      RETURN EXISTS (
        SELECT 1 FROM public.reports r
        JOIN public.cleanup_tasks t ON t.id = r.cleanup_task_id
        WHERE r.id = entity
          AND actor = ANY(coalesce(t.assigned_crew_ids, '{}'::uuid[]))
          AND t.route_status='ready'
          AND t.status::text IN ('created','pending','in_progress','partially_completed')
      );
    END IF;
    IF actor_role = 'citizen' THEN
      RETURN EXISTS (
        SELECT 1 FROM public.reports r
        WHERE r.id = entity
          AND r.user_id = actor
      );
    END IF;
    RETURN false;
  END IF;

  RETURN false;
END;
$function$;


REVOKE ALL ON FUNCTION storage_authority.can_read_cleanup_object(text,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION storage_authority.can_read_cleanup_object(text,text) TO authenticated;
COMMIT;
