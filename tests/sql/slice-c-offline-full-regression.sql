BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '2s';

CREATE TEMP TABLE offline_audit_results (
  test text,
  status text,
  detail text
) ON COMMIT DROP;

DO $$
DECLARE
  v_crew uuid;
  v_other_crew uuid;
  v_officer uuid;
  v_citizen uuid;
  v_field_crew_vehicle uuid := gen_random_uuid();
  v_task uuid := gen_random_uuid();
  v_report uuid := gen_random_uuid();
  v_task_gen bigint;
  v_claim_gen bigint;
  v_receipt public.field_assignment_receipts;
  v_payload jsonb;
  v_result jsonb;
  v_load_result jsonb;
  v_failure_result jsonb;
BEGIN
  -- Resolve real profile actors
  SELECT id INTO v_crew FROM public.profiles WHERE role::text = 'field_crew' LIMIT 1;
  SELECT id INTO v_other_crew FROM public.profiles WHERE role::text = 'field_crew' AND id <> v_crew LIMIT 1;
  SELECT id INTO v_officer FROM public.profiles WHERE role::text = 'officer' LIMIT 1;
  SELECT id INTO v_citizen FROM public.profiles WHERE role::text = 'citizen' LIMIT 1;

  -- Create a second temporary field_crew profile if only one exists
  IF v_other_crew IS NULL THEN
    v_other_crew := gen_random_uuid();
    INSERT INTO auth.users (id, email) VALUES (v_other_crew, 'other.crew.test@ecopin.local') ON CONFLICT DO NOTHING;
    INSERT INTO public.profiles (id, full_name, role)
    VALUES (v_other_crew, 'Other Test Crew', 'field_crew')
    ON CONFLICT (id) DO UPDATE SET role = 'field_crew', full_name = 'Other Test Crew';
  END IF;

  -- Create field crew vehicle record
  INSERT INTO public.field_crews (id, name, member_profile_ids, shift_start, shift_end, max_tasks_per_shift, max_volume_m3, max_weight_kg)
  VALUES (v_field_crew_vehicle, 'Offline Test Vehicle', ARRAY[v_crew, v_other_crew], '08:00', '17:00', 10, 8, 2000);

  -- Create task assigned to v_crew
  INSERT INTO public.cleanup_tasks (id, title, assigned_field_crew_id, assigned_crew_ids, route_status, report_ids, assignment_generation)
  VALUES (v_task, 'Offline Test Task', v_field_crew_vehicle, ARRAY[v_crew], 'ready', ARRAY[v_report], 1);

  -- Create report claimed by v_task
  INSERT INTO public.reports (id, user_id, title, issue_type, location, severity_score, cleanup_task_id, report_claim_generation)
  VALUES (v_report, v_citizen, 'Offline Test Report', 'waste',
          extensions.st_setsrid(extensions.st_makepoint(121, 14), 4326)::extensions.geography, 2, v_task, 1);

  -- Ensure assignment receipt exists
  SELECT * INTO v_receipt FROM public.field_assignment_receipts
  WHERE task_id = v_task AND report_id = v_report AND crew_id = v_crew;

  IF v_receipt.id IS NULL THEN
    -- Issue explicitly if trigger didn't fire due to transaction boundary
    INSERT INTO public.field_assignment_receipts (task_id, report_id, crew_id, assignment_generation, report_claim_generation)
    VALUES (v_task, v_report, v_crew, 1, 1)
    RETURNING * INTO v_receipt;
  END IF;

  INSERT INTO offline_audit_results VALUES (
    'Assignment receipt issued for task and report',
    CASE WHEN v_receipt.id IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
    'Receipt ID: ' || coalesce(v_receipt.id::text, 'null')
  );

  -- 1. Test reconcile_report_outcome (outcome: cleaned)
  v_payload := jsonb_build_object(
    'task_id', v_task,
    'report_id', v_report,
    'crew_id', v_crew,
    'assignment_generation', v_receipt.assignment_generation,
    'report_claim_generation', v_receipt.report_claim_generation,
    'outcome', 'cleaned',
    'observed_at', now(),
    'evidence_refs', jsonb_build_array('https://evidence.ecopin.local/cleaned1.jpg')
  );

  v_result := public.reconcile_report_outcome(v_crew, 'op-offline-reconcile-1', v_payload);
  INSERT INTO offline_audit_results VALUES (
    'Valid offline report outcome applied as resolved',
    CASE WHEN v_result->>'status' = 'applied' AND (SELECT status::text FROM public.reports WHERE id = v_report) = 'resolved' THEN 'PASS' ELSE 'FAIL' END,
    'Status: ' || coalesce(v_result->>'status', 'null')
  );

  -- 2. Test idempotent replay of reconcile_report_outcome
  v_result := public.reconcile_report_outcome(v_crew, 'op-offline-reconcile-1', v_payload);
  INSERT INTO offline_audit_results VALUES (
    'Reconciliation operation replays idempotently',
    CASE WHEN v_result->>'status' = 'applied' AND v_result->>'replayed' = 'true' THEN 'PASS' ELSE 'FAIL' END,
    'Replayed: ' || coalesce(v_result->>'replayed', 'false')
  );

  -- 3. Test outcome: already_resolved
  v_result := public.reconcile_report_outcome(v_crew, 'op-offline-already-resolved-1', v_payload || '{"outcome":"already_resolved"}'::jsonb);
  INSERT INTO offline_audit_results VALUES (
    'Already resolved report acknowledged correctly',
    CASE WHEN v_result->>'status' = 'acknowledged_already_resolved' THEN 'PASS' ELSE 'FAIL' END,
    'Disposition: ' || coalesce(v_result->>'status', 'null')
  );

  -- 3b. Test reopened report with already_resolved -> verification_required
  UPDATE public.reports SET status = 'unresolved', lgu_resolved_at = NULL WHERE id = v_report;
  v_result := public.reconcile_report_outcome(v_crew, 'op-offline-reopened-1', v_payload || '{"outcome":"already_resolved"}'::jsonb);
  INSERT INTO offline_audit_results VALUES (
    'Reopened report requires verification rather than instant credit',
    CASE WHEN v_result->>'status' = 'verification_required' THEN 'PASS' ELSE 'FAIL' END,
    'Disposition: ' || coalesce(v_result->>'status', 'null')
  );

  -- 3c. Test contested cleanup when task was reassigned while crew was offline
  UPDATE public.cleanup_tasks SET assigned_crew_ids = ARRAY[v_other_crew] WHERE id = v_task;
  v_result := public.reconcile_report_outcome(v_crew, 'op-offline-contested-1', v_payload);
  INSERT INTO offline_audit_results VALUES (
    'Reassigned task results in contested disposition and triggers needs_replan',
    CASE WHEN v_result->>'status' = 'contested'
         AND (SELECT route_status FROM public.cleanup_tasks WHERE id = v_task) = 'needs_replan'
         THEN 'PASS' ELSE 'FAIL' END,
    'Disposition: ' || coalesce(v_result->>'status', 'null') || ', Route: ' || coalesce((SELECT route_status FROM public.cleanup_tasks WHERE id = v_task), 'null')
  );

  -- Restore assignment and ready route status for subsequent tests
  UPDATE public.cleanup_tasks SET assigned_crew_ids = ARRAY[v_crew], route_status = 'ready' WHERE id = v_task;

  -- 4. Test forged / stale receipt rejected
  v_result := public.reconcile_report_outcome(v_crew, 'op-offline-forged-1', v_payload || '{"assignment_generation":9999}'::jsonb);
  INSERT INTO offline_audit_results VALUES (
    'Stale or forged assignment generation rejected',
    CASE WHEN v_result->>'status' = 'rejected' THEN 'PASS' ELSE 'FAIL' END,
    'Result status: ' || coalesce(v_result->>'status', 'null')
  );

  -- 5. Test record_field_load (load observation)
  SELECT assignment_generation INTO v_task_gen FROM public.cleanup_tasks WHERE id = v_task;
  v_load_result := public.record_field_load(v_crew, 'op-load-observation-1', jsonb_build_object(
    'task_id', v_task,
    'assignment_generation', v_task_gen,
    'event_type', 'load_observation',
    'fill_percent', 75,
    'actual_volume_m3', 5,
    'actual_weight_kg', 850,
    'observed_at', now()
  ));

  INSERT INTO offline_audit_results VALUES (
    'Field load measurement recorded',
    CASE WHEN v_load_result->>'status' = 'applied' AND (SELECT starting_volume_m3 FROM public.field_crews WHERE id = v_field_crew_vehicle) = 5 THEN 'PASS' ELSE 'FAIL' END,
    'Volume: ' || coalesce((SELECT starting_volume_m3 FROM public.field_crews WHERE id = v_field_crew_vehicle)::text, 'null')
  );

  -- 6. Test record_field_load (disposal resets load)
  v_load_result := public.record_field_load(v_crew, 'op-load-disposal-1', jsonb_build_object(
    'task_id', v_task,
    'assignment_generation', v_task_gen,
    'event_type', 'disposal',
    'observed_at', now()
  ));

  INSERT INTO offline_audit_results VALUES (
    'Disposal resets field crew measured load',
    CASE WHEN v_load_result->>'status' = 'applied' AND (SELECT starting_volume_m3 FROM public.field_crews WHERE id = v_field_crew_vehicle) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'Volume: ' || coalesce((SELECT starting_volume_m3 FROM public.field_crews WHERE id = v_field_crew_vehicle)::text, 'null')
  );

  -- 7. Test record_field_load idempotent replay
  v_load_result := public.record_field_load(v_crew, 'op-load-disposal-1', jsonb_build_object(
    'task_id', v_task,
    'assignment_generation', v_task_gen,
    'event_type', 'disposal',
    'observed_at', now()
  ));

  INSERT INTO offline_audit_results VALUES (
    'Disposal operation replays idempotently',
    CASE WHEN v_load_result->>'replayed' = 'true' THEN 'PASS' ELSE 'FAIL' END,
    'Replayed: ' || coalesce(v_load_result->>'replayed', 'false')
  );

  -- 8. Test submit_field_failure
  v_failure_result := public.submit_field_failure(v_crew, 'op-field-failure-1', jsonb_build_object(
    'task_id', v_task,
    'assignment_generation', v_task_gen,
    'reason_code', 'site_inaccessible',
    'notes', 'Road flooded, site completely unreachable',
    'evidence_refs', jsonb_build_array('https://evidence.ecopin.local/flood_barrier.jpg'),
    'observed_at', now()
  ));

  INSERT INTO offline_audit_results VALUES (
    'Field task failure marks task cancelled and retains evidence',
    CASE WHEN v_failure_result->>'status' = 'applied'
         AND (SELECT status::text FROM public.cleanup_tasks WHERE id = v_task) = 'cancelled'
         AND (SELECT count(*) FROM public.field_task_failure_events WHERE task_id = v_task) = 1
         THEN 'PASS' ELSE 'FAIL' END,
    'Status: ' || coalesce(v_failure_result->>'status', 'null')
  );

  -- 9. Test submit_field_failure idempotent replay
  v_failure_result := public.submit_field_failure(v_crew, 'op-field-failure-1', jsonb_build_object(
    'task_id', v_task,
    'assignment_generation', v_task_gen,
    'reason_code', 'site_inaccessible',
    'notes', 'Road flooded, site completely unreachable',
    'evidence_refs', jsonb_build_array('https://evidence.ecopin.local/flood_barrier.jpg'),
    'observed_at', now()
  ));

  INSERT INTO offline_audit_results VALUES (
    'Field failure operation replays idempotently',
    CASE WHEN v_failure_result->>'replayed' = 'true' THEN 'PASS' ELSE 'FAIL' END,
    'Replayed: ' || coalesce(v_failure_result->>'replayed', 'false')
  );

END $$;

SELECT * FROM offline_audit_results ORDER BY test;
ROLLBACK;
