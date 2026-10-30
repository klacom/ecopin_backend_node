-- PDT-06/PDT-08: replace unverified legacy barangay labels with the polygon resolver's decision.
-- Only rows still 'pending_reconciliation' are touched, so a re-run is a no-op. Administrative columns only:
-- user triggers are skipped (replica role) so no report version, claim generation, receipt or event is created.
BEGIN;
SET LOCAL lock_timeout='10s';
SET LOCAL session_replication_role=replica;

CREATE TABLE IF NOT EXISTS workflow_private.report_barangay_reconciliation_log(
 report_id uuid NOT NULL,reconciled_at timestamptz NOT NULL,
 old_barangay text,old_city text,old_status text NOT NULL,
 new_barangay text,new_city text,new_status text NOT NULL,new_candidates text[] NOT NULL,
 reason text NOT NULL CHECK(reason IN ('polygon_resolved','polygon_flagged','outside_boundaries','city_text_conflict','invalid_location')),
 PRIMARY KEY(report_id,reconciled_at)
);
ALTER TABLE workflow_private.report_barangay_reconciliation_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON workflow_private.report_barangay_reconciliation_log FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON workflow_private.report_barangay_reconciliation_log TO service_role;

CREATE TEMP TABLE reconcile_plan ON COMMIT DROP AS
WITH pending AS (
 SELECT r.id,r.barangay,r.city,r.barangay_resolution_status AS status,
  CASE WHEN r.location IS NULL THEN jsonb_build_object('status','invalid_coordinates','barangay',NULL,'candidates','[]'::jsonb)
   ELSE public.resolve_report_barangay(extensions.ST_Y(r.location::extensions.geometry),extensions.ST_X(r.location::extensions.geometry)) END AS res
 FROM public.reports r WHERE r.barangay_resolution_status='pending_reconciliation'
), decided AS (
 SELECT p.*,
  -- A polygon hit that the geocoder's own city text contradicts sits on a simplified edge: flag it, do not force it.
  (p.res->>'status'='resolved' AND p.city IS NOT NULL AND btrim(p.city)<>'' AND p.city IS DISTINCT FROM 'Pasig City') AS city_conflict
 FROM pending p
)
SELECT id,barangay AS old_barangay,city AS old_city,status AS old_status,
 CASE WHEN city_conflict THEN 'border' ELSE res->>'status' END AS new_status,
 CASE WHEN city_conflict THEN NULL ELSE res->>'barangay' END AS new_barangay,
 CASE WHEN res->>'status'='resolved' AND NOT city_conflict THEN 'Pasig City' ELSE city END AS new_city,
 coalesce(ARRAY(SELECT jsonb_array_elements_text(res->'candidates')),'{}'::text[]) AS new_candidates,
 CASE WHEN city_conflict THEN 'city_text_conflict'
  WHEN res->>'status'='resolved' THEN 'polygon_resolved'
  WHEN res->>'status'='unresolved' THEN 'outside_boundaries'
  WHEN res->>'status'='invalid_coordinates' THEN 'invalid_location'
  ELSE 'polygon_flagged' END AS reason
FROM decided;

-- A dataset problem would otherwise stamp every report as incomplete; stop and leave rows pending instead.
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM reconcile_plan WHERE new_status IN('dataset_incomplete','unavailable')) THEN
  RAISE EXCEPTION 'Barangay boundary dataset is incomplete; reports were left pending_reconciliation.' USING ERRCODE='55000';
 END IF;
END $$;

INSERT INTO workflow_private.report_barangay_reconciliation_log
 SELECT id,statement_timestamp(),old_barangay,old_city,old_status,new_barangay,new_city,new_status,new_candidates,reason FROM reconcile_plan;

UPDATE public.reports r SET barangay=p.new_barangay,city=p.new_city,barangay_resolution_status=p.new_status,
 barangay_candidates=p.new_candidates,barangay_resolution_checked_at=statement_timestamp()
FROM reconcile_plan p WHERE r.id=p.id AND r.barangay_resolution_status='pending_reconciliation';

COMMIT;
