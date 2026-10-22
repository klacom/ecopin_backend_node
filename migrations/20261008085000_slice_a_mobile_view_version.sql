begin;
-- Keep the legacy column order so CREATE OR REPLACE VIEW can add fc_version
-- without changing existing consumers of reports_view.
create or replace view public.reports_view with (security_invoker=true) as
select id,user_id,title,description,issue_type,location,validation_status,status,
  cluster_id,created_at,updated_at,notes,before_photo_url,after_photo_url,
  on_private_property,property_owner_consent_status,stage,satisfaction_rating,
  lgu_resolved_at,citizen_closed_at,is_overdue,severity_score,urgency_score,
  ra9003_category,ml_predicted_class,ml_confidence,ml_probabilities,
  deadline_at,is_outlier,fc_version
from public.reports;
commit;
