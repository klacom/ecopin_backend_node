-- PDT-16: aggregate operational data; no report/person records leave this RPC.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.get_barangay_operational_analytics(actor uuid,start_month date,end_month date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE stamp timestamptz := statement_timestamp(); first_at timestamptz; until_at timestamptz; result jsonb;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('admin','officer')) THEN
  RAISE EXCEPTION 'Staff analytics access required' USING ERRCODE='42501';
 END IF;
 IF start_month IS NULL OR end_month IS NULL OR start_month<>date_trunc('month',start_month)::date
   OR end_month<>date_trunc('month',end_month)::date OR start_month>end_month
   OR start_month<date '2000-01-01' OR end_month>date_trunc('month',stamp AT TIME ZONE 'Asia/Manila')::date
   OR end_month >= start_month + interval '24 months' THEN
  RAISE EXCEPTION 'Select a calendar-month range of at most 24 months, ending no later than this month' USING ERRCODE='22023';
 END IF;
 IF (SELECT count(*) FROM public.pasig_barangay_roster)<>30 THEN
  RAISE EXCEPTION 'The official 30-barangay roster must be reconciled first' USING ERRCODE='55000';
 END IF;
 first_at := start_month::timestamp AT TIME ZONE 'Asia/Manila';
 until_at := (end_month + interval '1 month')::timestamp AT TIME ZONE 'Asia/Manila';
 WITH groups AS (
  SELECT psgc_code AS key,psgc_code,name FROM public.pasig_barangay_roster
  UNION ALL SELECT 'unassigned',NULL,'Unassigned location'
  UNION ALL SELECT 'all',NULL,'All locations'
 ), base AS MATERIALIZED (
  SELECT coalesce(b.psgc_code,'unassigned') AS key,r.created_at,r.lgu_resolved_at,
   coalesce(r.validation_status::text,'unknown') AS validation,
   coalesce(r.status::text,'unknown') IN ('resolved','completed','closed','waiting_for_feedback') AS is_resolved,
   coalesce(r.status::text,'unknown') NOT IN ('resolved','completed','closed','waiting_for_feedback','rejected','withdrawn','cancelled')
     AND coalesce(r.validation_status::text,'unknown')<>'rejected' AS is_open,
   r.created_at>=first_at AND r.created_at<until_at AS cohort,
   stamp-r.created_at AS age,
   CASE WHEN r.lgu_resolved_at>=r.created_at AND r.lgu_resolved_at<=stamp
    THEN extract(epoch FROM (r.lgu_resolved_at-r.created_at))/3600.0 END AS duration_hours
  FROM public.reports r LEFT JOIN public.pasig_barangay_roster b
   ON r.barangay_resolution_status='resolved' AND b.name=r.barangay
  WHERE r.created_at IS NOT NULL AND isfinite(r.created_at) AND r.created_at<=stamp
 ), expanded AS (
  SELECT x.*, x.is_resolved AND x.duration_hours IS NOT NULL AND x.lgu_resolved_at>=first_at AND x.lgu_resolved_at<until_at AS resolved_in_period
  FROM (SELECT * FROM base UNION ALL SELECT 'all',created_at,lgu_resolved_at,validation,is_resolved,is_open,cohort,age,duration_hours FROM base) x
 ), stats AS (
  SELECT key,
   count(*) FILTER(WHERE cohort) AS report_count,
   count(*) FILTER(WHERE cohort AND validation IN ('approved','validated','rejected')) AS verified_count,
   count(*) FILTER(WHERE cohort AND validation IN ('approved','validated')) AS approved_count,
   count(*) FILTER(WHERE cohort AND validation='rejected') AS rejected_count,
   count(*) FILTER(WHERE cohort AND validation NOT IN ('approved','validated','rejected')) AS pending_count,
   count(*) FILTER(WHERE is_open) AS backlog_total,
   count(*) FILTER(WHERE is_open AND age < interval '1 day') AS backlog_under_1_day,
   count(*) FILTER(WHERE is_open AND age >= interval '1 day' AND age < interval '3 days') AS backlog_1_2_days,
   count(*) FILTER(WHERE is_open AND age >= interval '3 days' AND age < interval '7 days') AS backlog_3_6_days,
   count(*) FILTER(WHERE is_open AND age >= interval '7 days' AND age < interval '30 days') AS backlog_7_29_days,
   count(*) FILTER(WHERE is_open AND age >= interval '30 days') AS backlog_30_plus_days,
   count(*) FILTER(WHERE resolved_in_period) AS resolution_count,
   count(*) FILTER(WHERE is_resolved AND lgu_resolved_at IS NULL) AS missing_resolution_count,
   count(*) FILTER(WHERE is_resolved AND lgu_resolved_at IS NOT NULL AND duration_hours IS NULL) AS invalid_resolution_count,
   percentile_cont(0.5) WITHIN GROUP(ORDER BY duration_hours) FILTER(WHERE resolved_in_period) AS median_resolution_hours,
   percentile_cont(0.9) WITHIN GROUP(ORDER BY duration_hours) FILTER(WHERE resolved_in_period) AS p90_resolution_hours,
   avg(duration_hours) FILTER(WHERE resolved_in_period) AS average_resolution_hours
  FROM expanded GROUP BY key
 ), monthly_counts AS (
  SELECT key,date_trunc('month',created_at AT TIME ZONE 'Asia/Manila')::date AS month,count(*) AS report_count
  FROM expanded WHERE cohort GROUP BY key,date_trunc('month',created_at AT TIME ZONE 'Asia/Manila')::date
 ), monthly AS (
  SELECT g.key,jsonb_agg(jsonb_build_object('month',to_char(m,'YYYY-MM'),'report_count',coalesce(c.report_count,0)) ORDER BY m) AS values
  FROM groups g CROSS JOIN generate_series(start_month::timestamp,end_month::timestamp,interval '1 month') m
  LEFT JOIN monthly_counts c ON c.key=g.key AND c.month=m::date GROUP BY g.key
 ), rows AS (
  SELECT g.key,g.name,jsonb_build_object('key',g.key,'name',g.name,'psgc_code',g.psgc_code,
   'report_count',coalesce(s.report_count,0),
   'verified_count',coalesce(s.verified_count,0),
   'approved_count',coalesce(s.approved_count,0),
   'rejected_count',coalesce(s.rejected_count,0),
   'pending_count',coalesce(s.pending_count,0),
   'backlog_total',coalesce(s.backlog_total,0),
   'backlog_under_1_day',coalesce(s.backlog_under_1_day,0),
   'backlog_1_2_days',coalesce(s.backlog_1_2_days,0),
   'backlog_3_6_days',coalesce(s.backlog_3_6_days,0),
   'backlog_7_29_days',coalesce(s.backlog_7_29_days,0),
   'backlog_30_plus_days',coalesce(s.backlog_30_plus_days,0),
   'resolution_count',coalesce(s.resolution_count,0),
   'missing_resolution_count',coalesce(s.missing_resolution_count,0),
   'invalid_resolution_count',coalesce(s.invalid_resolution_count,0),
   'verification_rate_percent',round(100.0*s.verified_count/nullif(s.report_count,0),1),
   'median_resolution_hours',s.median_resolution_hours,'p90_resolution_hours',s.p90_resolution_hours,
   'average_resolution_hours',s.average_resolution_hours,'monthly',m.values) AS value
  FROM groups g LEFT JOIN stats s ON s.key=g.key JOIN monthly m ON m.key=g.key
 ) SELECT jsonb_build_object(
  'generated_at',stamp,'timezone','Asia/Manila','start_month',to_char(start_month,'YYYY-MM'),'end_month',to_char(end_month,'YYYY-MM'),
  'total',(SELECT value FROM rows WHERE key='all'),
  'groups',(SELECT jsonb_agg(value ORDER BY (key='unassigned'),name) FROM rows WHERE key<>'all'),
  'quality',jsonb_build_object('excluded_creation_timestamps',
    (SELECT count(*) FROM public.reports WHERE created_at IS NULL OR NOT isfinite(created_at) OR created_at>stamp))
 ) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_barangay_operational_analytics(uuid,date,date) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_barangay_operational_analytics(uuid,date,date) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
