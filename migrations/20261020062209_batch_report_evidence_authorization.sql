SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='30s';

-- Keep the existing detail authorization rules as the source of truth.
CREATE FUNCTION public.read_authorized_report_evidence_ids(actor uuid, report_ids uuid[])
RETURNS TABLE(id uuid)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path=''
AS $$
WITH requested AS MATERIALIZED (
  SELECT DISTINCT report_id AS id
  FROM unnest(report_ids) AS input(report_id)
  WHERE report_id IS NOT NULL
  LIMIT 100
)
SELECT requested.id
FROM requested
WHERE public.read_authorized_report_detail(actor, requested.id) IS NOT NULL
   OR EXISTS (
     SELECT 1 FROM public.public_reports AS report
     WHERE report.id=requested.id AND report.location_precision='exact'
   );
$$;

REVOKE ALL ON FUNCTION public.read_authorized_report_evidence_ids(uuid,uuid[])
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_authorized_report_evidence_ids(uuid,uuid[])
TO service_role;
