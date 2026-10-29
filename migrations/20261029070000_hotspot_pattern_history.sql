-- PDT-19: one consistent, server-only history source. Depends on PDT-08.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.read_hotspot_pattern_history(p_max_reports integer DEFAULT 5000)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE stamp timestamptz:=statement_timestamp(); origin timestamptz; result jsonb; zone_rows jsonb;
BEGIN
 IF p_max_reports IS NULL OR p_max_reports<1 OR p_max_reports>5000 THEN
  RAISE EXCEPTION 'Processing limit must be between 1 and 5000' USING ERRCODE='22023';
 END IF;
 origin:=date_trunc('week',stamp AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
 SELECT jsonb_agg(jsonb_build_object('id',r.psgc_code,'psgc_code',r.psgc_code,'zone_name',r.name,'zone_type','barangay',
  'boundary_geojson',z.boundary_geojson,'centroid_lat',z.centroid_lat,'centroid_lng',z.centroid_lng) ORDER BY r.psgc_code)
 INTO zone_rows FROM public.pasig_barangay_roster r JOIN public.spatial_zones z ON z.zone_type='barangay' AND z.zone_name=r.name
 WHERE z.boundary_geojson->>'type' IN ('Polygon','MultiPolygon') AND z.centroid_lat BETWEEN -90 AND 90 AND z.centroid_lng BETWEEN -180 AND 180;
 IF jsonb_array_length(coalesce(zone_rows,'[]'::jsonb))<>30 THEN
  RAISE EXCEPTION 'Reconcile the complete official 30-barangay baseline first' USING ERRCODE='55000';
 END IF;
 WITH base AS MATERIALIZED (
  SELECT r.id,r.created_at,b.psgc_code,
   CASE WHEN extensions.GeometryType(r.location::extensions.geometry)='POINT' AND extensions.ST_SRID(r.location::extensions.geometry)=4326 THEN extensions.ST_X(r.location::extensions.geometry) END AS longitude,
   CASE WHEN extensions.GeometryType(r.location::extensions.geometry)='POINT' AND extensions.ST_SRID(r.location::extensions.geometry)=4326 THEN extensions.ST_Y(r.location::extensions.geometry) END AS latitude
  FROM public.reports r LEFT JOIN public.pasig_barangay_roster b ON r.barangay_resolution_status='resolved' AND r.barangay=b.name
  WHERE r.created_at>=origin-interval '52 weeks' AND r.created_at<stamp AND isfinite(r.created_at)
   AND r.validation_status::text IN ('approved','validated') AND NOT coalesce(r.flagged_severe,false)
   AND coalesce(r.status::text,'unknown') NOT IN ('rejected','withdrawn','cancelled')
 ), eligible AS MATERIALIZED (
  SELECT *,coalesce(psgc_code IS NOT NULL AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180,false) AS usable FROM base
 ), weekly AS (
  SELECT psgc_code,date_trunc('week',created_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS week_start,count(*) AS report_count
  FROM eligible WHERE usable AND created_at<origin GROUP BY psgc_code,date_trunc('week',created_at AT TIME ZONE 'UTC')
 ), recent AS (SELECT * FROM eligible WHERE created_at>=stamp-interval '90 days')
 SELECT jsonb_build_object('as_of',stamp,'history_start',stamp-interval '90 days','week_origin',origin,'forecast_history_start',origin-interval '52 weeks',
  'zones',zone_rows,'reports',CASE WHEN (SELECT count(*) FROM recent WHERE usable)>p_max_reports THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'created_at',created_at,'barangay_code',psgc_code,'latitude',latitude,'longitude',longitude) ORDER BY created_at,id) FROM recent WHERE usable),'[]'::jsonb) END,
  'weekly_history',coalesce((SELECT jsonb_agg(jsonb_build_object('zone_id',psgc_code,'week_start',week_start,'report_count',report_count) ORDER BY psgc_code,week_start) FROM weekly),'[]'::jsonb),
  'quality',jsonb_build_object('eligible_reports_90',(SELECT count(*) FROM recent),'included_reports_90',(SELECT count(*) FROM recent WHERE usable),
    'excluded_unreconciled_90',(SELECT count(*) FROM recent WHERE psgc_code IS NULL),
    'excluded_invalid_location_90',(SELECT count(*) FROM recent WHERE psgc_code IS NOT NULL AND NOT usable))) INTO result;
 IF (result->'quality'->>'included_reports_90')::integer>p_max_reports THEN
  RAISE EXCEPTION 'History exceeds the synchronous processing limit; no points were sampled' USING ERRCODE='54000';
 END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.read_hotspot_pattern_history(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_hotspot_pattern_history(integer) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
