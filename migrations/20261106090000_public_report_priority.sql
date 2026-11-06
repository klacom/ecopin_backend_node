-- Append the selected urgency only; retain the current public row/privacy projection.
BEGIN;
GRANT SELECT (citizen_priority) ON public.reports TO ecopin_public_map_reader;
DO $migration$
DECLARE existing_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'public_reports'
      AND column_name = 'citizen_priority'
  ) THEN
    existing_definition := regexp_replace(pg_get_viewdef('public.public_reports'::regclass, true), ';\s*$', '');
    EXECUTE format(
      'CREATE OR REPLACE VIEW public.public_reports WITH (security_barrier=true, security_invoker=false) AS SELECT visible.*, source.citizen_priority FROM (%s) visible JOIN public.reports source ON source.id = visible.id',
      existing_definition
    );
  END IF;
END
$migration$;
COMMENT ON COLUMN public.public_reports.citizen_priority IS 'Citizen-selected urgent/non_urgent priority; not severity or SWMO urgency approval. NULL means not specified.';
NOTIFY pgrst, 'reload schema';
COMMIT;
