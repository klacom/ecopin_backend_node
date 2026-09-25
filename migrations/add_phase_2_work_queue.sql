-- Migration: Add Phase 2 Environmental Work Queue
-- Description: Updates clusters, cleanup_tasks, and field_crews to support the decoupled work queue and consolidation.

-- 1. Update clusters table
-- We keep 'unresolved' temporarily for backward compatibility with existing data
ALTER TABLE clusters
  DROP CONSTRAINT IF EXISTS clusters_status_check;

ALTER TABLE clusters
  ADD CONSTRAINT clusters_status_check 
  CHECK (status IN ('new', 'prioritized', 'queued', 'scheduled', 'in_progress', 'resolved', 'needs_verification', 'monitoring', 'deferred', 'escalated', 'unresolved'));

ALTER TABLE clusters
  ADD COLUMN IF NOT EXISTS estimated_effort_minutes INT DEFAULT 60,
  ADD COLUMN IF NOT EXISTS recommended_task_type TEXT DEFAULT 'Cleanup';

-- 2. Update cleanup_tasks table
ALTER TABLE cleanup_tasks
  ADD COLUMN IF NOT EXISTS task_type TEXT DEFAULT 'Cleanup' 
  CHECK (task_type IN ('Cleanup', 'Investigation', 'Verification', 'Emergency Response', 'Reinspection', 'Monitoring', 'Escalation', 'Deferred')),
  ADD COLUMN IF NOT EXISTS cluster_ids UUID[] DEFAULT '{}';

-- 3. Update field_crews table for capacity planning
ALTER TABLE field_crews
  ADD COLUMN IF NOT EXISTS shift_start TIME,
  ADD COLUMN IF NOT EXISTS shift_end TIME;

-- 4. Add dispatch consolidation setting
INSERT INTO optimization_settings (key, value)
VALUES ('dispatch_consolidation_radius', '200')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- 5. Update the RPC that creates clusters so they start as 'new' instead of 'unresolved'
CREATE OR REPLACE FUNCTION upsert_cluster_for_reports(
  p_report_ids UUID[],
  p_issue_type TEXT,
  p_severity TEXT,
  p_radius_meters FLOAT
) RETURNS UUID AS $$
DECLARE
  v_centroid GEOGRAPHY;
  v_cluster_id UUID;
BEGIN
  -- Compute centroid
  SELECT ST_Centroid(ST_Union(location::geometry))::geography
  INTO v_centroid
  FROM reports
  WHERE id = ANY(p_report_ids);

  -- For this simplified version, we just create a new cluster.
  -- The real logic finds existing clusters within radius, but for ML we'll just insert
  INSERT INTO clusters (center, issue_type, severity, status, radius_meters)
  VALUES (v_centroid, p_issue_type, p_severity, 'new', p_radius_meters)
  RETURNING id INTO v_cluster_id;

  -- Update reports
  UPDATE reports
  SET cluster_id = v_cluster_id
  WHERE id = ANY(p_report_ids);

  RETURN v_cluster_id;
END;
$$ LANGUAGE plpgsql;
