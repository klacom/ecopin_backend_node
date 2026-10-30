-- PDT-23: submission-age backstop; independent of the configured response SLA.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE workflow_private.unprocessed_alert_deliveries (
 report_id uuid NOT NULL REFERENCES public.reports(id) ON DELETE CASCADE,
 recipient_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 age_day integer NOT NULL CHECK(age_day>=5),
 delivered_at timestamptz NOT NULL DEFAULT statement_timestamp(),
 PRIMARY KEY(report_id,recipient_id,age_day)
);
ALTER TABLE workflow_private.unprocessed_alert_deliveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON workflow_private.unprocessed_alert_deliveries FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT ON workflow_private.unprocessed_alert_deliveries TO service_role;

CREATE VIEW workflow_private.unprocessed_report_alerts WITH (security_invoker=true) AS
 SELECT report_id,created_at,age_days,missing_acknowledgement,missing_assignment,
  CASE WHEN age_days>=5 THEN 'overdue' ELSE 'approaching' END AS state
 FROM (
  SELECT r.id AS report_id,r.created_at,
   floor(extract(epoch FROM(statement_timestamp()-r.created_at))/86400)::integer AS age_days,
   NOT (coalesce(r.stage::text,'') IN ('acknowledged','responded','in_progress')
    OR coalesce(r.status::text,'') IN ('acknowledged','responded','in_progress')
    OR EXISTS(SELECT 1 FROM public.operational_events e WHERE e.report_id=r.id AND e.event_type='acknowledgement' AND e.time_basis='server')
    OR coalesce(t.status::text,'') IN ('en_route','in_progress','partially_completed')) AS missing_acknowledgement,
   NOT (t.id IS NOT NULL AND coalesce(t.status::text,'') IN ('created','pending','assigned','en_route','in_progress','partially_completed')
    AND (coalesce(cardinality(t.assigned_crew_ids),0)>0 OR t.assigned_field_crew_id IS NOT NULL)) AS missing_assignment
  FROM public.reports r LEFT JOIN public.cleanup_tasks t ON t.id=r.cleanup_task_id
  WHERE r.created_at IS NOT NULL AND isfinite(r.created_at) AND r.created_at>=timestamptz '2000-01-01 00:00:00Z'
   AND r.created_at<=statement_timestamp()-interval '96 hours'
   AND coalesce(r.status::text,'') NOT IN ('resolved','completed','closed','waiting_for_feedback','rejected','withdrawn','cancelled')
   AND coalesce(r.stage::text,'') NOT IN ('resolved','completed','closed','waiting_for_feedback','rejected','withdrawn','cancelled')
   AND coalesce(r.validation_status::text,'')<>'rejected'
 ) s WHERE missing_acknowledgement OR missing_assignment;
REVOKE ALL ON workflow_private.unprocessed_report_alerts FROM PUBLIC,anon,authenticated;
GRANT SELECT ON workflow_private.unprocessed_report_alerts TO service_role;

CREATE FUNCTION public.read_unprocessed_report_alerts(actor uuid,cursor_created timestamptz DEFAULT NULL,cursor_id uuid DEFAULT NULL,page_limit integer DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=actor AND p.role::text IN ('officer','admin')
  AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp())) THEN
  RAISE EXCEPTION 'Active staff access required' USING ERRCODE='42501';
 END IF;
 IF page_limit IS NULL OR page_limit<1 OR page_limit>100 OR (cursor_created IS NULL)<>(cursor_id IS NULL)
  OR (cursor_created IS NOT NULL AND NOT isfinite(cursor_created)) THEN
  RAISE EXCEPTION 'Invalid alert pagination' USING ERRCODE='22023';
 END IF;
 WITH base AS MATERIALIZED (SELECT * FROM workflow_private.unprocessed_report_alerts),
 page AS (SELECT * FROM base WHERE cursor_created IS NULL OR (created_at,report_id)>(cursor_created,cursor_id)
  ORDER BY created_at,report_id LIMIT page_limit+1),
 shown AS (SELECT * FROM page ORDER BY created_at,report_id LIMIT page_limit)
 SELECT jsonb_build_object('version','unprocessed-alerts-v1','generated_at',statement_timestamp(),
  'total',(SELECT count(*) FROM base),'overdue_count',(SELECT count(*) FROM base WHERE state='overdue'),
  'approaching_count',(SELECT count(*) FROM base WHERE state='approaching'),
  'reports',coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY created_at,report_id) FROM shown s),'[]'::jsonb),
  'next_cursor',CASE WHEN (SELECT count(*) FROM page)>page_limit THEN
   (SELECT jsonb_build_object('created_at',created_at,'report_id',report_id) FROM shown ORDER BY created_at DESC,report_id DESC LIMIT 1) END)
 INTO result;
 RETURN result;
END; $$;

CREATE FUNCTION public.escalate_unprocessed_reports() RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE result jsonb; locked_ids uuid[];
BEGIN
 -- Report locks coordinate with assignment/resolution writers; the ledger also handles duplicate workers.
 SELECT coalesce(array_agg(id),'{}'::uuid[]) INTO locked_ids FROM (
  SELECT r.id FROM public.reports r JOIN workflow_private.unprocessed_report_alerts q ON q.report_id=r.id
  WHERE q.age_days>=5 AND EXISTS(SELECT 1 FROM public.profiles p WHERE p.role::text IN ('officer','admin')
   AND (p.suspended_until IS NULL OR p.suspended_until<=statement_timestamp()) AND NOT EXISTS(
    SELECT 1 FROM workflow_private.unprocessed_alert_deliveries d WHERE d.report_id=r.id AND d.recipient_id=p.id AND d.age_day=q.age_days))
  ORDER BY r.created_at,r.id LIMIT 500 FOR UPDATE OF r SKIP LOCKED
 ) locked;
 -- Re-read eligibility after acquiring report locks instead of trusting the pre-lock scan.
 WITH recipients AS MATERIALIZED (
  SELECT id FROM public.profiles WHERE role::text IN ('officer','admin')
   AND (suspended_until IS NULL OR suspended_until<=statement_timestamp())
 ), candidates AS MATERIALIZED (
  SELECT q.report_id AS id,q.age_days,q.missing_acknowledgement,q.missing_assignment
  FROM workflow_private.unprocessed_report_alerts q WHERE q.report_id=ANY(locked_ids) AND q.age_days>=5
 ), claims AS (
  INSERT INTO workflow_private.unprocessed_alert_deliveries(report_id,recipient_id,age_day)
  SELECT c.id,p.id,c.age_days FROM candidates c CROSS JOIN recipients p
  ON CONFLICT DO NOTHING RETURNING *
 ), inserted AS (
  INSERT INTO public.notifications(user_id,report_id,type,title,body)
  SELECT d.recipient_id,d.report_id,'general'::public.notification_type,
   CASE WHEN EXISTS(SELECT 1 FROM workflow_private.unprocessed_alert_deliveries old WHERE old.report_id=d.report_id AND old.recipient_id=d.recipient_id)
    THEN 'Unprocessed incident reminder' ELSE '5-day incident escalation' END,
   format('Report %s has waited %s days since submission. Missing: %s. Review the incident and coordinate action.',d.report_id,d.age_day,
    concat_ws(' and ',CASE WHEN c.missing_acknowledgement THEN 'acknowledgement' END,CASE WHEN c.missing_assignment THEN 'crew assignment' END))
  FROM claims d JOIN candidates c ON c.id=d.report_id RETURNING report_id
 ) SELECT jsonb_build_object('reports_checked',(SELECT count(*) FROM candidates),'notifications_created',(SELECT count(*) FROM inserted)) INTO result;
 RETURN result;
END; $$;
REVOKE ALL ON FUNCTION public.read_unprocessed_report_alerts(uuid,timestamptz,uuid,integer),public.escalate_unprocessed_reports() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.read_unprocessed_report_alerts(uuid,timestamptz,uuid,integer),public.escalate_unprocessed_reports() TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
