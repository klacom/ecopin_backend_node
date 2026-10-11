-- Contract phase: deploy repaired callers before this migration.
ALTER POLICY "Reports are viewable by authenticated users" ON public.reports USING (
  ((SELECT public.get_auth_user_role())::text IN ('officer','admin'))
  OR user_id=(SELECT auth.uid())
  OR (((SELECT public.get_auth_user_role())::text='field_crew') AND EXISTS (
    SELECT 1 FROM public.cleanup_tasks ct
    WHERE ct.id=reports.cleanup_task_id
      AND ct.route_status='ready'
      AND ct.status::text IN ('created','pending','in_progress','partially_completed')
      AND (SELECT auth.uid())=ANY(COALESCE(ct.assigned_crew_ids,'{}'::uuid[]))
  ))
);
DROP POLICY "Enable read access for all users" ON public.reports;
REVOKE ALL ON public.reports,public.reports_view FROM anon;
REVOKE SELECT ("id","user_id","title","description","issue_type","location","validation_status","status","cluster_id","created_at","updated_at","notes","before_photo_url","after_photo_url","on_private_property","property_owner_consent_status","stage","satisfaction_rating","lgu_resolved_at","citizen_closed_at","is_overdue","ai_score","flagged_severe","severe_violation_category","manual_review_id","severity_score","urgency_score","ra9003_category","ml_predicted_class","ml_confidence","ml_probabilities","cleanup_task_id","scale_level","obstruction_level","severity_level","severity_factors","idempotency_key","deadline_at","fc_version","before_photo_hash","after_photo_hash","sla_started_at","lifecycle_state","matured_at","breached_at","report_claim_generation","hazard_class","hazard_model_version","hazard_confidence","hazard_decision_source","hazard_classified_at") ON public.reports FROM anon;
REVOKE SELECT ("id","user_id","title","description","issue_type","location","validation_status","status","cluster_id","created_at","updated_at","notes","before_photo_url","after_photo_url","on_private_property","property_owner_consent_status","stage","satisfaction_rating","lgu_resolved_at","citizen_closed_at","is_overdue","ai_score","flagged_severe","severe_violation_category","manual_review_id","severity_score","urgency_score","ra9003_category","ml_predicted_class","ml_confidence","ml_probabilities","cleanup_task_id","scale_level","obstruction_level","severity_level","severity_factors","idempotency_key","deadline_at","fc_version","before_photo_hash","after_photo_hash","sla_started_at","lifecycle_state","matured_at","breached_at","report_claim_generation","hazard_class","hazard_model_version","hazard_confidence","hazard_decision_source","hazard_classified_at") ON public.reports_view FROM anon;
