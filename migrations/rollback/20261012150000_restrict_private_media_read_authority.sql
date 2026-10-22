BEGIN;
SET LOCAL lock_timeout='2s';
-- Fail closed during repair; do not restore the known overbroad read helper.
CREATE OR REPLACE FUNCTION storage_authority.can_read_cleanup_object(bucket text,object_path text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $function$ SELECT false; $function$;
COMMIT;