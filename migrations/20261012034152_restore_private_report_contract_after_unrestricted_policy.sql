BEGIN;
-- Restore the agreed public projection / private detail contract.
DROP POLICY IF EXISTS "Allow anon read reports" ON public.reports;
REVOKE SELECT ON TABLE public.reports,public.reports_view FROM anon;
DO $repair$
DECLARE relation regclass; column_names text;
BEGIN
 FOREACH relation IN ARRAY ARRAY['public.reports'::regclass,'public.reports_view'::regclass] LOOP
  SELECT string_agg(pg_catalog.quote_ident(attname),',' ORDER BY attnum)
   INTO column_names FROM pg_catalog.pg_attribute
   WHERE attrelid=relation AND attnum>0 AND NOT attisdropped;
  EXECUTE pg_catalog.format('REVOKE SELECT (%s) ON TABLE %s FROM anon',column_names,relation);
 END LOOP;
END;
$repair$;
GRANT SELECT ON TABLE public.public_reports TO anon,authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
