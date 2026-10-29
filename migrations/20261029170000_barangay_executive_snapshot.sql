-- PDT-31: read-only bundle; both aggregate calls use this statement's MVCC snapshot.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.get_barangay_executive_analytics(actor uuid,report_month date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE monthly jsonb; comparison jsonb;
BEGIN
 -- Existing aggregate validates desk role, month bounds and reconciled 30-barangay roster.
 monthly:=public.get_barangay_operational_analytics(actor,report_month,report_month);
 comparison:=public.get_barangay_operational_analytics(actor,greatest(date '2000-01-01',(report_month-interval '1 month')::date),report_month);
 RETURN jsonb_build_object('version','barangay-executive-v1','generated_at',monthly->'generated_at','monthly',monthly,'comparison',comparison);
END; $$;
REVOKE ALL ON FUNCTION public.get_barangay_executive_analytics(uuid,date) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_barangay_executive_analytics(uuid,date) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
