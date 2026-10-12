BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '2s';

CREATE TEMP TABLE w02_results(test text, status text, detail text) ON COMMIT DROP;
GRANT INSERT, SELECT ON w02_results TO anon, authenticated, service_role;

CREATE FUNCTION pg_temp.w02_assert(label text, condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO w02_results VALUES(label, CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END, 'Condition=' || coalesce(condition::text, 'null'));
END;
$$;

DO $$
DECLARE
  v_officer_id uuid;
  v_lead_id uuid;
  v_new_member_id uuid := gen_random_uuid();
  v_stranger_crew_id uuid := gen_random_uuid();
  v_team_id uuid := gen_random_uuid();
  v_run_id uuid := gen_random_uuid();
  v_route_id uuid := gen_random_uuid();
  v_task_id uuid := gen_random_uuid();
  v_report_id uuid := gen_random_uuid();
  v_version bigint;
  v_photo_res jsonb;
  v_outcome_res jsonb;
  v_read_res jsonb;
  v_can_exec boolean;
  v_receipt_count integer;
  v_route_count integer;
BEGIN
  -- Discover desk officer and lead profiles
  SELECT id INTO v_officer_id FROM public.profiles WHERE role::text='officer' LIMIT 1;
  SELECT id INTO v_lead_id FROM public.profiles WHERE role::text='field_crew' LIMIT 1;

  -- Fallbacks if running on bare container without fixtures
  IF v_officer_id IS NULL THEN
    v_officer_id := '00000000-0000-0000-0000-000000000004';
    INSERT INTO auth.users(id) VALUES (v_officer_id) ON CONFLICT DO NOTHING;
    INSERT INTO public.profiles(id, full_name, role) VALUES (v_officer_id, 'Synthetic officer', 'officer')
      ON CONFLICT (id) DO UPDATE SET role = 'officer';
  END IF;

  IF v_lead_id IS NULL THEN
    v_lead_id := '00000000-0000-0000-0000-000000000003';
    INSERT INTO auth.users(id) VALUES (v_lead_id) ON CONFLICT DO NOTHING;
    INSERT INTO public.profiles(id, full_name, role) VALUES (v_lead_id, 'Synthetic lead', 'field_crew')
      ON CONFLICT (id) DO UPDATE SET role = 'field_crew';
  END IF;

  -- Setup recruit and stranger
  INSERT INTO auth.users(id) VALUES (v_new_member_id), (v_stranger_crew_id) ON CONFLICT DO NOTHING;
  INSERT INTO public.profiles(id, full_name, role) VALUES
    (v_new_member_id, 'Synthetic recruit', 'field_crew'),
    (v_stranger_crew_id, 'Synthetic bystander crew', 'field_crew')
    ON CONFLICT (id) DO UPDATE SET role = 'field_crew', full_name = EXCLUDED.full_name;

  -- Setup team
  INSERT INTO public.field_crews(id, name, shift_start, shift_end, max_tasks_per_shift, team_lead_profile_id, member_profile_ids, max_volume_m3, max_weight_kg, starting_volume_m3, starting_weight_kg, load_measured_at)
    VALUES (v_team_id, 'Bravo Team', '08:00', '17:00', 10, v_lead_id, ARRAY[v_lead_id], 10.0, 1000.0, 0.0, 0.0, now());

  -- Setup optimization run & route
  INSERT INTO public.optimization_runs(id, criteria) VALUES (v_run_id, '{}'::jsonb);
  INSERT INTO public.crew_routes(id, optimization_run_id, crew_id, start_depot, end_depot)
    VALUES (v_route_id, v_run_id, v_team_id,
      extensions.st_setsrid(extensions.st_makepoint(121.0, 14.5), 4326)::extensions.geography,
      extensions.st_setsrid(extensions.st_makepoint(121.0, 14.5), 4326)::extensions.geography);

  -- Setup task assigned to Bravo Team with initial lead
  INSERT INTO public.cleanup_tasks(id, title, assigned_field_crew_id, assigned_crew_ids, route_status, status, crew_route_id)
    VALUES (v_task_id, 'Bravo sweep', v_team_id, ARRAY[v_lead_id], 'ready', 'pending', v_route_id);

  -- Setup waypoint
  INSERT INTO public.route_waypoints(crew_route_id, cleanup_task_id, sequence_order, latitude, longitude)
    VALUES (v_route_id, v_task_id, 1, 14.5, 121.0);

  -- Setup report
  INSERT INTO public.reports(id, user_id, title, location, cleanup_task_id, validation_status)
    VALUES (v_report_id, v_lead_id, 'Bravo target', extensions.st_setsrid(extensions.st_makepoint(121.0, 14.5), 4326)::extensions.geography, v_task_id, 'approved');

  -- 1. Initial state: recruit is NOT yet on the team
  SELECT count(*) INTO v_receipt_count FROM public.field_assignment_receipts WHERE task_id = v_task_id AND crew_id = v_new_member_id;
  PERFORM pg_temp.w02_assert('Recruit initially has no receipt', v_receipt_count = 0);

  SELECT workflow_private.can_execute_task(v_new_member_id, t) INTO v_can_exec FROM public.cleanup_tasks t WHERE id = v_task_id;
  PERFORM pg_temp.w02_assert('Recruit initially cannot execute task', v_can_exec IS FALSE);

  -- 2. Desk officer adds recruit to Bravo Team
  PERFORM public.change_field_crew_member(v_team_id, v_officer_id, v_new_member_id, 'add');

  -- 3. Verify route visibility under field_crew role
  SELECT count(*) INTO v_route_count FROM public.crew_routes r
    WHERE r.id = v_route_id AND EXISTS (
      SELECT 1 FROM public.field_crews c
      WHERE c.id = r.crew_id AND (c.team_lead_profile_id = v_new_member_id OR v_new_member_id = ANY(COALESCE(c.member_profile_ids, '{}'::uuid[])))
    );
  PERFORM pg_temp.w02_assert('New member can view team route', v_route_count = 1);

  -- 4. Verify task assigned_crew_ids now includes recruit
  PERFORM pg_temp.w02_assert('Task assigned_crew_ids includes recruit',
    EXISTS (SELECT 1 FROM public.cleanup_tasks WHERE id = v_task_id AND v_new_member_id = ANY(assigned_crew_ids)));

  -- 5. Verify assignment receipt issued for recruit
  SELECT count(*) INTO v_receipt_count FROM public.field_assignment_receipts WHERE task_id = v_task_id AND crew_id = v_new_member_id;
  PERFORM pg_temp.w02_assert('Assignment receipt issued for recruit', v_receipt_count >= 1);

  -- 6. Verify can_execute_task returns true
  SELECT workflow_private.can_execute_task(v_new_member_id, t) INTO v_can_exec FROM public.cleanup_tasks t WHERE id = v_task_id;
  PERFORM pg_temp.w02_assert('Recruit can execute assigned task', v_can_exec IS TRUE);

  -- 7. Verify stranger crew cannot execute task
  SELECT workflow_private.can_execute_task(v_stranger_crew_id, t) INTO v_can_exec FROM public.cleanup_tasks t WHERE id = v_task_id;
  PERFORM pg_temp.w02_assert('Stranger crew cannot execute task', v_can_exec IS FALSE);

  -- 8. Verify read_authorized_cleanup_tasks provides detail access for recruit
  v_read_res := public.read_authorized_cleanup_tasks(v_new_member_id, v_task_id);
  PERFORM pg_temp.w02_assert('Recruit can read task detail',
    jsonb_array_length(v_read_res) = 1 AND v_read_res->0->>'access_level' = 'detail');

  -- 9. Verify recruit can set before photo
  SELECT fc_version INTO v_version FROM public.cleanup_tasks WHERE id = v_task_id;
  v_photo_res := public.set_task_photo(v_task_id, v_new_member_id, 'before', 'https://storage.invalid/b1.jpg', 'hash123', v_version);
  PERFORM pg_temp.w02_assert('Recruit can upload task before photo',
    v_photo_res->>'status' = 'success' AND v_photo_res->'server_record'->>'status' = 'in_progress');

  -- 10. Verify recruit can submit task completion outcome
  v_outcome_res := public.submit_task_outcome(v_task_id, v_new_member_id, 'completed', 'Cleaned up completely');
  PERFORM pg_temp.w02_assert('Recruit can submit terminal outcome',
    v_outcome_res->>'status' = 'success' AND v_outcome_res->'server_record'->>'status' = 'completed');

  -- 11. Verify removing member synchronizes active tasks
  INSERT INTO public.cleanup_tasks(id, title, assigned_field_crew_id, assigned_crew_ids, route_status, status, crew_route_id)
    VALUES ('00000000-0000-0000-0000-000000000188', 'Bravo follow-up', v_team_id, ARRAY[v_lead_id, v_new_member_id], 'ready', 'pending', v_route_id);

  PERFORM public.change_field_crew_member(v_team_id, v_officer_id, v_new_member_id, 'remove');

  PERFORM pg_temp.w02_assert('Member removed from active task assigned_crew_ids',
    NOT EXISTS (SELECT 1 FROM public.cleanup_tasks WHERE id = '00000000-0000-0000-0000-000000000188' AND v_new_member_id = ANY(assigned_crew_ids)));

  -- 12. Removed member cannot execute new task
  SELECT workflow_private.can_execute_task(v_new_member_id, t) INTO v_can_exec
    FROM public.cleanup_tasks t WHERE id = '00000000-0000-0000-0000-000000000188';
  PERFORM pg_temp.w02_assert('Removed member cannot execute new task', v_can_exec IS FALSE);

  -- Self-cleaning teardown for repeatable re-runs
  DELETE FROM public.field_assignment_receipts WHERE task_id IN (v_task_id, '00000000-0000-0000-0000-000000000188');
  DELETE FROM public.reports WHERE id = v_report_id;
  DELETE FROM public.route_waypoints WHERE crew_route_id = v_route_id;
  DELETE FROM public.cleanup_tasks WHERE id IN (v_task_id, '00000000-0000-0000-0000-000000000188');
  DELETE FROM public.crew_routes WHERE id = v_route_id;
  DELETE FROM public.optimization_runs WHERE id = v_run_id;
  DELETE FROM public.field_crews WHERE id = v_team_id;
  DELETE FROM public.profiles WHERE id IN (v_new_member_id, v_stranger_crew_id);
  DELETE FROM auth.users WHERE id IN (v_new_member_id, v_stranger_crew_id);

END $$;

SELECT test, status, detail FROM w02_results;
COMMIT;
