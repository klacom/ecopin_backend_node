BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.reports ADD COLUMN citizen_landmark text
  CHECK (citizen_landmark IS NULL OR char_length(citizen_landmark) BETWEEN 1 AND 300);
COMMENT ON COLUMN public.reports.citizen_landmark IS
  'Optional citizen-provided visual landmark. Supplemental text only; never use for GIS coordinates, geocoding, barangay assignment or proximity checks.';

-- Preserve the existing operational authorization, masks, owner and grants.
-- The public map projection intentionally keeps its existing location contract.
DO $$ DECLARE definition text; BEGIN
 definition:=rtrim(pg_get_viewdef('public.reports_view'::regclass,true),E';\n ');
 EXECUTE 'CREATE OR REPLACE VIEW public.reports_view WITH (security_barrier=true,security_invoker=false) AS SELECT v.*,r.citizen_landmark FROM ('
   ||definition||') v JOIN public.reports r ON r.id=v.id';
END $$;
NOTIFY pgrst,'reload schema';
COMMIT;
