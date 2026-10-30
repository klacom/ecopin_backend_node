-- PDT-23: start escalation without notifying staff about the backlog that already exists.
-- Scheduled notices (and daily reminders) only cover reports submitted after the baseline cutoff. The red/amber dashboard
-- is unchanged and still lists every stagnant report. To include older reports later, delete the baseline row.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE IF NOT EXISTS workflow_private.unprocessed_escalation_baseline(
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),cutoff timestamptz NOT NULL,set_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
ALTER TABLE workflow_private.unprocessed_escalation_baseline ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON workflow_private.unprocessed_escalation_baseline FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON workflow_private.unprocessed_escalation_baseline TO service_role;
INSERT INTO workflow_private.unprocessed_escalation_baseline(singleton,cutoff) VALUES(true,statement_timestamp()) ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.escalate_unprocessed_reports() RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE result jsonb; locked_ids uuid[];
BEGIN
 -- Report locks coordinate with assignment/resolution writers; the ledger also handles duplicate workers.
 SELECT coalesce(array_agg(id),'{}'::uuid[]) INTO locked_ids FROM (
  SELECT r.id FROM public.reports r JOIN workflow_private.unprocessed_report_alerts q ON q.report_id=r.id
  WHERE q.age_days>=5 AND q.created_at>(SELECT coalesce(max(b.cutoff),'-infinity'::timestamptz) FROM workflow_private.unprocessed_escalation_baseline b) AND EXISTS(SELECT 1 FROM public.profiles p WHERE p.role::text IN ('officer','admin')
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
  FROM workflow_private.unprocessed_report_alerts q WHERE q.report_id=ANY(locked_ids) AND q.age_days>=5 AND q.created_at>(SELECT coalesce(max(b.cutoff),'-infinity'::timestamptz) FROM workflow_private.unprocessed_escalation_baseline b)
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
REVOKE ALL ON FUNCTION public.escalate_unprocessed_reports() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.escalate_unprocessed_reports() TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
