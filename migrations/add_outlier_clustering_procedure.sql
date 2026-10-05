-- Function to create outlier clusters
CREATE OR REPLACE FUNCTION create_outlier_clusters()
RETURNS TABLE (
  cluster_id UUID,
  report_id UUID,
  coordinates GEOMETRY(Point, 4326)
) AS $$
BEGIN
  RETURN QUERY
  WITH outlier_reports AS (
    SELECT id, location, issue_type, severity
    FROM reports
    WHERE is_outlier = true
      AND cluster_id IS NULL
  ),
  inserted_clusters AS (
    INSERT INTO clusters (centroid, bounding_box, issue_type, severity, is_outlier, status)
    SELECT 
      location AS centroid,
      ST_Buffer(location::geography, 10)::geometry AS bounding_box,
      issue_type,
      severity,
      true AS is_outlier,
      'Pending Assignment' AS status
    FROM outlier_reports
    RETURNING id, centroid
  ),
  updated_reports AS (
    UPDATE reports r
    SET cluster_id = ic.id
    FROM inserted_clusters ic, outlier_reports or_
    WHERE r.id = or_.id
      AND ST_Equals(ic.centroid, or_.location)
    RETURNING r.id AS report_id, r.cluster_id, r.location
  )
  SELECT 
    ur.cluster_id,
    ur.report_id,
    ur.location AS coordinates
  FROM updated_reports ur;
END;
$$ LANGUAGE plpgsql;
