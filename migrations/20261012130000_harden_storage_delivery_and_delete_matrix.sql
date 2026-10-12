-- Migration: 20261012130000_harden_storage_delivery_and_delete_matrix.sql
-- Description: Hardens storage buckets against unauthenticated enumeration,
--              scopes SELECT and DELETE policies to assigned crews, report owners, and officers/admins,
--              establishes storage_authority.can_read_cleanup_object,
--              secures evidence and cleanup buckets against anonymous public download,
--              and cleans up duplicate avatar read policy.

SET LOCAL lock_timeout = '2s';

CREATE SCHEMA IF NOT EXISTS storage_authority;
GRANT USAGE ON SCHEMA storage_authority TO authenticated;

-- 1. Helper function to scope read access for cleanup tasks and report cleanup
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
      );
    END IF;
    IF actor_role = 'citizen' THEN
      RETURN EXISTS (
        SELECT 1 FROM public.reports r
        WHERE (r.cleanup_task_id = entity OR r.id = ANY(
          SELECT unnest(coalesce(t.report_ids, '{}'::uuid[])) FROM public.cleanup_tasks t WHERE t.id = entity
        ))
        AND r.user_id = actor
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

REVOKE ALL ON FUNCTION storage_authority.can_read_cleanup_object(text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION storage_authority.can_read_cleanup_object(text, text) TO authenticated;

-- 2. Remove duplicate read policy on avatars
DROP POLICY IF EXISTS "public_read 1oj01fe_0" ON storage.objects;

-- 3. Restrict SELECT on Report Evidence to authenticated owners and officers/admins
DROP POLICY IF EXISTS "Public can view Report Evidence" ON storage.objects;
DROP POLICY IF EXISTS "Authorized users can view Report Evidence" ON storage.objects;
CREATE POLICY "Authorized users can view Report Evidence" ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'Report Evidence'
  AND (
    (storage.foldername(name))[1] = (SELECT auth.uid())::text
    OR ((SELECT public.get_auth_user_role())::text IN ('officer', 'admin'))
  )
);

-- 4. Scope SELECT on Cleanup Task Photos to assigned crew, report owners, and officers/admins
DROP POLICY IF EXISTS "Public can view Cleanup Task Photos" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can view Cleanup Task Photos" ON storage.objects;
DROP POLICY IF EXISTS "Authorized users can view Cleanup Task Photos" ON storage.objects;
CREATE POLICY "Authorized users can view Cleanup Task Photos" ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'Cleanup Task Photos'
  AND storage_authority.can_read_cleanup_object(bucket_id, name)
);

-- 5. Scope SELECT on Report Cleanup to assigned crew, report owners, and officers/admins
DROP POLICY IF EXISTS "Public can view Report Cleanup" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can view Report Cleanup" ON storage.objects;
DROP POLICY IF EXISTS "Authorized users can view Report Cleanup" ON storage.objects;
CREATE POLICY "Authorized users can view Report Cleanup" ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'Report Cleanup'
  AND storage_authority.can_read_cleanup_object(bucket_id, name)
);

-- 6. Establish DELETE policies for Cleanup Task Photos and Report Cleanup
DROP POLICY IF EXISTS "Authorized users can delete Cleanup Task Photos" ON storage.objects;
CREATE POLICY "Authorized users can delete Cleanup Task Photos" ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'Cleanup Task Photos'
  AND storage_authority.can_upload_cleanup_object(bucket_id, name)
);

DROP POLICY IF EXISTS "Authorized users can delete Report Cleanup" ON storage.objects;
CREATE POLICY "Authorized users can delete Report Cleanup" ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'Report Cleanup'
  AND storage_authority.can_upload_cleanup_object(bucket_id, name)
);

-- 7. Establish DELETE policy for Report Evidence (citizen owner or staff)
DROP POLICY IF EXISTS "Users and officers can delete Report Evidence" ON storage.objects;
CREATE POLICY "Users and officers can delete Report Evidence" ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'Report Evidence'
  AND (
    (storage.foldername(name))[1] = (SELECT auth.uid())::text
    OR ((SELECT public.get_auth_user_role())::text IN ('officer', 'admin'))
  )
);

-- 8. Secure Report Evidence and Cleanup buckets against anonymous public download
UPDATE storage.buckets SET public = false WHERE id IN ('Report Evidence', 'Cleanup Task Photos', 'Report Cleanup');
