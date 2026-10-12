BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '2s';

CREATE TEMP TABLE task_guard_results(test text, status text) ON COMMIT DROP;
GRANT INSERT, SELECT ON task_guard_results TO service_role, anon, authenticated;

CREATE FUNCTION pg_temp.task_assert(label text, condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN 
  INSERT INTO task_guard_results VALUES(label, CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END); 
END $$;

DO $$
DECLARE
  crew_assigned uuid;
  crew_stranger uuid := gen_random_uuid();
  citizen_user uuid;
  active_task_id uuid;
  unready_task_id uuid;
  notif_id uuid := gen_random_uuid();
  updated_count integer;
  observed text;
BEGIN
  -- 1. Identify test fixtures
  SELECT id INTO crew_assigned FROM public.profiles WHERE role::text = 'field_crew' LIMIT 1;
  SELECT id INTO citizen_user FROM public.profiles WHERE role::text = 'citizen' LIMIT 1;

  IF crew_assigned IS NULL OR citizen_user IS NULL THEN
    RAISE EXCEPTION 'Prerequisite fixtures missing';
  END IF;

  -- Create stranger crew fixture
  INSERT INTO auth.users(id, email) VALUES (crew_stranger, 'stranger_crew@example.invalid');
  INSERT INTO public.profiles(id, role, is_email_verified) VALUES (crew_stranger, 'field_crew', true)
  ON CONFLICT (id) DO UPDATE SET role = 'field_crew';

  -- 2. Setup mock tasks
  active_task_id := gen_random_uuid();
  unready_task_id := gen_random_uuid();

  INSERT INTO public.cleanup_tasks (
    id, cluster_id, title, status, route_status, assigned_crew_ids, assignment_generation, is_custom, created_by
  ) VALUES 
    (active_task_id, NULL, 'Active Ready Task', 'created', 'ready', ARRAY[crew_assigned], 1, true, citizen_user),
    (unready_task_id, NULL, 'Unready Task', 'created', 'needs_replan', ARRAY[crew_assigned], 1, true, citizen_user);

  -- 3. Setup mock notification
  INSERT INTO public.notifications (id, user_id, type, title, body, is_read)
  VALUES (notif_id, citizen_user, 'general', 'Initial Title', 'Initial Body', false);

  -- ==========================================
  -- TEST BLOCK A: Assigned Crew Allowed Update
  -- ==========================================
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', crew_assigned::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', crew_assigned::text, true);
  PERFORM set_config('role', 'authenticated', true);

  -- Assigned crew updates allowed operational field (status -> in_progress)
  UPDATE public.cleanup_tasks SET status = 'in_progress' WHERE id = active_task_id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  PERFORM pg_temp.task_assert('Assigned crew can update active ready task status', updated_count = 1);

  -- ==========================================
  -- TEST BLOCK B: Stranger Crew Denied Update
  -- ==========================================
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', crew_stranger::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', crew_stranger::text, true);

  -- Stranger crew tries to update the task -> RLS filters it out (0 rows updated)
  UPDATE public.cleanup_tasks SET status = 'completed' WHERE id = active_task_id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  PERFORM pg_temp.task_assert('Stranger crew update is filtered out by RLS', updated_count = 0);

  -- ==========================================
  -- TEST BLOCK C: Unready Route Task Denied
  -- ==========================================
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', crew_assigned::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', crew_assigned::text, true);

  UPDATE public.cleanup_tasks SET status = 'in_progress' WHERE id = unready_task_id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  PERFORM pg_temp.task_assert('Unready route task update is filtered out by RLS', updated_count = 0);

  -- ==========================================
  -- TEST BLOCK D: Tampering with Immutable Fields Denied (42501)
  -- ==========================================
  -- 1. Try to tamper with created_by
  BEGIN
    UPDATE public.cleanup_tasks SET created_by = crew_assigned WHERE id = active_task_id;
    PERFORM pg_temp.task_assert('Tampering with created_by denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.task_assert('Tampering with created_by denied', true);
  END;

  -- 2. Try to tamper with assigned_crew_ids
  BEGIN
    UPDATE public.cleanup_tasks SET assigned_crew_ids = ARRAY[crew_stranger] WHERE id = active_task_id;
    PERFORM pg_temp.task_assert('Tampering with assigned_crew_ids denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.task_assert('Tampering with assigned_crew_ids denied', true);
  END;

  -- 3. Try to tamper with assignment_generation
  BEGIN
    UPDATE public.cleanup_tasks SET assignment_generation = 99 WHERE id = active_task_id;
    PERFORM pg_temp.task_assert('Tampering with assignment_generation denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.task_assert('Tampering with assignment_generation denied', true);
  END;

  -- 4. Try to tamper with route_status
  BEGIN
    UPDATE public.cleanup_tasks SET route_status = 'needs_replan' WHERE id = active_task_id;
    PERFORM pg_temp.task_assert('Tampering with route_status denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.task_assert('Tampering with route_status denied', true);
  END;

  -- ==========================================
  -- TEST BLOCK E: Notification Updates
  -- ==========================================
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', citizen_user::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', citizen_user::text, true);

  -- User updates is_read -> Allowed
  UPDATE public.notifications SET is_read = true WHERE id = notif_id;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  PERFORM pg_temp.task_assert('User can mark notification as read', updated_count = 1);

  -- User tries to tamper with title -> Denied with 42501
  BEGIN
    UPDATE public.notifications SET title = 'Spoofed Notification Title' WHERE id = notif_id;
    PERFORM pg_temp.task_assert('Tampering with notification title denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.task_assert('Tampering with notification title denied', true);
  END;

  -- User tries to tamper with body -> Denied with 42501
  BEGIN
    UPDATE public.notifications SET body = 'Spoofed Notification Body' WHERE id = notif_id;
    PERFORM pg_temp.task_assert('Tampering with notification body denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.task_assert('Tampering with notification body denied', true);
  END;

  -- User tries to tamper with user_id -> Denied with 42501
  BEGIN
    UPDATE public.notifications SET user_id = crew_assigned WHERE id = notif_id;
    PERFORM pg_temp.task_assert('Tampering with notification user_id denied', false);
  EXCEPTION WHEN sqlstate '42501' THEN
    PERFORM pg_temp.task_assert('Tampering with notification user_id denied', true);
  END;

  PERFORM set_config('role', 'postgres', true);
END $$;

SELECT * FROM task_guard_results ORDER BY test;
ROLLBACK;
