-- Rollback script for Sweeper Workflow

-- Task 1.3: Drop triggers and functions
DROP TRIGGER IF EXISTS trigger_check_task_outlier ON cleanup_tasks;
DROP FUNCTION IF EXISTS check_task_outlier_consistency();

DROP TRIGGER IF EXISTS trigger_check_cluster_outlier ON clusters;
DROP FUNCTION IF EXISTS check_cluster_outlier_consistency();

-- Task 1.2: Drop tables
DROP TABLE IF EXISTS sweeper_audit_log;
DROP TABLE IF EXISTS work_time_configuration;
DROP TABLE IF EXISTS sweeper_configuration;

-- Task 1.1: Drop indexes and columns

-- Drop composite indexes
DROP INDEX IF EXISTS idx_reports_outlier_clustering;
DROP INDEX IF EXISTS idx_reports_sla_detection;

-- Drop partial indexes
DROP INDEX IF EXISTS idx_cleanup_tasks_is_outlier;
DROP INDEX IF EXISTS idx_clusters_is_outlier;
DROP INDEX IF EXISTS idx_reports_is_outlier;

-- Revert reports_view back to not include is_outlier
DROP VIEW IF EXISTS reports_view;
CREATE VIEW public.reports_view AS
SELECT
  id,
  user_id,
  title,
  description,
  issue_type,
  location,
  validation_status,
  status,
  cluster_id,
  created_at,
  updated_at,
  notes,
  before_photo_url,
  after_photo_url,
  on_private_property,
  property_owner_consent_status,
  stage,
  satisfaction_rating,
  lgu_resolved_at,
  citizen_closed_at,
  is_overdue,
  severity_score,
  urgency_score,
  ra9003_category,
  ml_predicted_class,
  ml_confidence,
  ml_probabilities
FROM
  reports;

-- Drop columns
ALTER TABLE cleanup_tasks DROP COLUMN IF EXISTS is_outlier;
ALTER TABLE clusters DROP COLUMN IF EXISTS is_outlier;
ALTER TABLE reports DROP COLUMN IF EXISTS is_outlier;
