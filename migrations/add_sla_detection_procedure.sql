-- Stored procedure for SLA detection
CREATE OR REPLACE FUNCTION detect_sla_outliers()
RETURNS TABLE (
  report_id UUID,
  breach_duration NUMERIC,
  flagged_at TIMESTAMPTZ
) AS $$
DECLARE
  sla_threshold NUMERIC;
BEGIN
  -- Get current SLA threshold
  SELECT (parameter_value->>'hours')::NUMERIC INTO sla_threshold
  FROM sweeper_configuration
  WHERE parameter_name = 'sla_threshold';
  
  -- Update and return flagged reports
  RETURN QUERY
  UPDATE reports
  SET is_outlier = true, updated_at = NOW()
  WHERE status NOT IN ('resolved', 'rejected')
    AND is_outlier = false
    AND EXTRACT(EPOCH FROM (NOW() - created_at)) / 3600 > sla_threshold
  RETURNING 
    id AS report_id,
    EXTRACT(EPOCH FROM (NOW() - created_at)) / 3600 AS breach_duration,
    NOW() AS flagged_at;
END;
$$ LANGUAGE plpgsql;
