-- Migration 012: Seed Large Scenario for Phase 2 Work Queue
-- Description: Generates 300+ realistic environmental clusters with associated reports

DO $$
DECLARE
  v_user_id UUID;
  v_cluster_id UUID;
  i INT;
  j INT;
  v_lat FLOAT;
  v_lng FLOAT;
  v_issue_types TEXT[] := ARRAY['waste', 'flooding', 'pollution', 'infrastructure'];
  v_issue TEXT;
  v_report_count INT;
BEGIN
  SELECT id INTO v_user_id FROM profiles WHERE role = 'citizen' LIMIT 1;
  
  IF v_user_id IS NULL THEN
    RAISE NOTICE 'No citizen profile found. Cannot seed scenario.';
    RETURN;
  END IF;

  RAISE NOTICE 'Seeding 350 clusters for the Phase 2 Work Queue...';
  
  FOR i IN 1..350 LOOP
    v_lat := 14.50 + (random() * 0.15);
    v_lng := 121.00 + (random() * 0.15);
    v_issue := v_issue_types[1 + floor(random() * 4)];
    v_report_count := floor(random() * 5) + 1;
    
    INSERT INTO clusters (
      center, issue_type, severity, status, radius_meters, 
      estimated_effort_minutes, recommended_task_type, created_at, report_count
    ) VALUES (
      ST_MakePoint(v_lng, v_lat)::geometry, 
      v_issue, 
      CASE WHEN random() > 0.8 THEN 'high' WHEN random() > 0.4 THEN 'medium' ELSE 'low' END,
      'new',
      100,
      floor(random() * 120 + 30)::int,
      'Cleanup',
      NOW() - (random() * 30 * interval '1 day'),
      v_report_count
    ) RETURNING id INTO v_cluster_id;

    FOR j IN 1..v_report_count LOOP
      INSERT INTO reports (
        title, description, issue_type, location, severity_score, urgency_score, 
        status, validation_status, created_at, user_id, cluster_id
      ) VALUES (
        'Auto Generated Report ' || i || '-' || j,
        'Simulation report for cluster ' || v_cluster_id,
        v_issue,
        ST_MakePoint(v_lng + (random()*0.001 - 0.0005), v_lat + (random()*0.001 - 0.0005))::geography,
        floor(random() * 50 + 50)::int,
        floor(random() * 3 + 1)::int, -- values 1, 2, 3
        'unresolved',
        'approved',
        NOW() - (random() * 30 * interval '1 day'),
        v_user_id,
        v_cluster_id
      );
    END LOOP;
  END LOOP;
  
  RAISE NOTICE 'Successfully seeded 350 clusters.';
END;
$$;
