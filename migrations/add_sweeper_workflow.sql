-- Task 1.1: Database schema foundation

-- Add is_outlier column to reports, clusters, cleanup_tasks
ALTER TABLE reports ADD COLUMN IF NOT EXISTS is_outlier BOOLEAN DEFAULT false;
ALTER TABLE clusters ADD COLUMN IF NOT EXISTS is_outlier BOOLEAN DEFAULT false;
ALTER TABLE cleanup_tasks ADD COLUMN IF NOT EXISTS is_outlier BOOLEAN DEFAULT false;

-- Create partial indexes
CREATE INDEX IF NOT EXISTS idx_reports_is_outlier ON reports(is_outlier) WHERE is_outlier = true;
CREATE INDEX IF NOT EXISTS idx_clusters_is_outlier ON clusters(is_outlier) WHERE is_outlier = true;
CREATE INDEX IF NOT EXISTS idx_cleanup_tasks_is_outlier ON cleanup_tasks(is_outlier) WHERE is_outlier = true;

-- Create composite indexes for SLA detection and clustering queries
CREATE INDEX IF NOT EXISTS idx_reports_sla_detection ON reports(status, is_outlier, created_at);
CREATE INDEX IF NOT EXISTS idx_reports_outlier_clustering ON reports(is_outlier, cluster_id) WHERE is_outlier = true;

-- Recreate reports_view to include is_outlier
CREATE OR REPLACE VIEW public.reports_view AS
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
  ml_probabilities,
  deadline_at,
  is_outlier
FROM
  reports;

-- Task 1.2: Configuration tables and audit log table

-- Create sweeper_configuration table
CREATE TABLE IF NOT EXISTS sweeper_configuration (
    parameter_name VARCHAR(100) PRIMARY KEY,
    parameter_value JSONB NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_by VARCHAR(255)
);

-- Create work_time_configuration table
CREATE TABLE IF NOT EXISTS work_time_configuration (
    report_type VARCHAR(100) PRIMARY KEY,
    work_time_minutes INTEGER NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create sweeper_audit_log table
CREATE TABLE IF NOT EXISTS sweeper_audit_log (
    id SERIAL PRIMARY KEY,
    event_type VARCHAR(100) NOT NULL,
    entity_type VARCHAR(100) NOT NULL,
    entity_id VARCHAR(255) NOT NULL,
    user_id VARCHAR(255),
    event_data JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_sweeper_audit_entity ON sweeper_audit_log(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_sweeper_audit_user ON sweeper_audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_sweeper_audit_event ON sweeper_audit_log(event_type);

-- Insert default configuration values
INSERT INTO sweeper_configuration (parameter_name, parameter_value, updated_by)
VALUES 
    ('sla_threshold', '{"hours": 48}'::jsonb, 'system'),
    ('shift_duration', '{"hours": 8}'::jsonb, 'system'),
    ('time_buffer', '{"percent": 10}'::jsonb, 'system')
ON CONFLICT (parameter_name) DO UPDATE SET parameter_value = EXCLUDED.parameter_value;

-- Insert default work times for all report types
INSERT INTO work_time_configuration (report_type, work_time_minutes)
VALUES 
    ('waste', 30),
    ('flooding', 60),
    ('pollution', 45),
    ('infrastructure', 120),
    ('illegal_logging', 90),
    ('pending', 30),
    ('others', 30)
ON CONFLICT (report_type) DO UPDATE SET work_time_minutes = EXCLUDED.work_time_minutes;

-- Task 1.3: Create referential integrity triggers

-- Create trigger function check_cluster_outlier_consistency()
CREATE OR REPLACE FUNCTION check_cluster_outlier_consistency()
RETURNS TRIGGER AS $$
DECLARE
    mismatched_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO mismatched_count
    FROM reports
    WHERE cluster_id = NEW.id AND is_outlier != NEW.is_outlier;
    
    IF mismatched_count > 0 THEN
        RAISE EXCEPTION 'Cluster is_outlier flag (%) must match all contained reports', NEW.is_outlier;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for clusters
CREATE OR REPLACE TRIGGER trigger_check_cluster_outlier
    BEFORE UPDATE OF is_outlier ON clusters
    FOR EACH ROW
    EXECUTE FUNCTION check_cluster_outlier_consistency();

-- Create trigger function check_task_outlier_consistency()
CREATE OR REPLACE FUNCTION check_task_outlier_consistency()
RETURNS TRIGGER AS $$
DECLARE
    mismatched_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO mismatched_count
    FROM clusters
    WHERE id = ANY(NEW.cluster_ids) AND is_outlier != NEW.is_outlier;
    
    IF mismatched_count > 0 THEN
        RAISE EXCEPTION 'Task is_outlier flag (%) must match all contained clusters', NEW.is_outlier;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for cleanup_tasks
-- Assuming cluster_ids is a column in cleanup_tasks, checking its type
CREATE OR REPLACE TRIGGER trigger_check_task_outlier
    BEFORE INSERT OR UPDATE OF is_outlier, cluster_ids ON cleanup_tasks
    FOR EACH ROW
    EXECUTE FUNCTION check_task_outlier_consistency();
