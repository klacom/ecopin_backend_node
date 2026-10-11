BEGIN;
SET LOCAL statement_timeout='30s'; SET LOCAL lock_timeout='5s';
CREATE TEMP TABLE retention_results(test text,status text) ON COMMIT DROP;
GRANT INSERT,SELECT ON retention_results TO service_role,anon,authenticated;
CREATE FUNCTION pg_temp.retention_assert(label text,condition boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO retention_results VALUES(label,CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END); END $$;

DO $$
DECLARE
  caller text;
  uid uuid;
  t_unexpired uuid;
  t_recent uuid;
  t_used_recent uuid;
  t_cutoff_safe uuid;
  t_cutoff_del uuid;
  t_oldest uuid;
  t_middle uuid;
  t_younger uuid;
  del_count integer;
  err_caught boolean;
  res jsonb;
  c_running bigint;
  c_recent bigint;
  c_old_succ bigint;
  c_old_fail bigint;
BEGIN
  -- Use synthetic user fixture
  SELECT id INTO uid FROM auth.users LIMIT 1;
  IF uid IS NULL THEN RAISE EXCEPTION 'No auth fixture user found'; END IF;

  -- 1. Create synthetic verification rows
  -- Unexpired token
  INSERT INTO public.email_verifications(id, user_id, expires_at)
    VALUES (gen_random_uuid(), uid, statement_timestamp() + interval '1 day')
    RETURNING id INTO t_unexpired;

  -- Recently expired token (10 days ago)
  INSERT INTO public.email_verifications(id, user_id, expires_at)
    VALUES (gen_random_uuid(), uid, statement_timestamp() - interval '10 days')
    RETURNING id INTO t_recent;

  -- Used recently expired token (15 days ago, used 15 days ago)
  INSERT INTO public.email_verifications(id, user_id, expires_at, used_at)
    VALUES (gen_random_uuid(), uid, statement_timestamp() - interval '15 days', statement_timestamp() - interval '15 days')
    RETURNING id INTO t_used_recent;

  -- Exact cutoff boundary: 30 days minus 1 second (should be preserved)
  INSERT INTO public.email_verifications(id, user_id, expires_at)
    VALUES (gen_random_uuid(), uid, statement_timestamp() - interval '30 days' + interval '1 second')
    RETURNING id INTO t_cutoff_safe;

  -- Exact cutoff boundary: 30 days plus 1 second (should be deleted)
  INSERT INTO public.email_verifications(id, user_id, expires_at)
    VALUES (gen_random_uuid(), uid, statement_timestamp() - interval '30 days' - interval '1 second')
    RETURNING id INTO t_cutoff_del;

  -- Ordered deletion test candidates: 60 days ago (oldest), 50 days ago (middle), 40 days ago (younger)
  INSERT INTO public.email_verifications(id, user_id, expires_at)
    VALUES (gen_random_uuid(), uid, statement_timestamp() - interval '60 days')
    RETURNING id INTO t_oldest;
  INSERT INTO public.email_verifications(id, user_id, expires_at)
    VALUES (gen_random_uuid(), uid, statement_timestamp() - interval '50 days')
    RETURNING id INTO t_middle;
  INSERT INTO public.email_verifications(id, user_id, expires_at)
    VALUES (gen_random_uuid(), uid, statement_timestamp() - interval '40 days')
    RETURNING id INTO t_younger;

  -- 2. Test oldest-first bounded removal: limit 1 should pick t_oldest
  EXECUTE 'SET LOCAL ROLE service_role';
  del_count := public.cleanup_expired_email_verifications(1);
  PERFORM pg_temp.retention_assert('Bounded removal deletes exactly limit rows', del_count = 1);
  PERFORM pg_temp.retention_assert('Oldest expired token is deleted first', NOT EXISTS(SELECT 1 FROM public.email_verifications WHERE id = t_oldest));
  PERFORM pg_temp.retention_assert('Middle expired token remains after limit 1', EXISTS(SELECT 1 FROM public.email_verifications WHERE id = t_middle));
  PERFORM pg_temp.retention_assert('Younger expired token remains after limit 1', EXISTS(SELECT 1 FROM public.email_verifications WHERE id = t_younger));

  -- 3. Cleanup remaining expired rows (t_middle, t_younger, t_cutoff_del)
  del_count := public.cleanup_expired_email_verifications(100);
  PERFORM pg_temp.retention_assert('Subsequent batch deletes remaining eligible expired rows', del_count >= 3);
  PERFORM pg_temp.retention_assert('Middle expired token deleted', NOT EXISTS(SELECT 1 FROM public.email_verifications WHERE id = t_middle));
  PERFORM pg_temp.retention_assert('Younger expired token deleted', NOT EXISTS(SELECT 1 FROM public.email_verifications WHERE id = t_younger));
  PERFORM pg_temp.retention_assert('Cutoff past 30d token deleted', NOT EXISTS(SELECT 1 FROM public.email_verifications WHERE id = t_cutoff_del));

  -- 4. Verify preserved tokens
  PERFORM pg_temp.retention_assert('Unexpired token is preserved', EXISTS(SELECT 1 FROM public.email_verifications WHERE id = t_unexpired));
  PERFORM pg_temp.retention_assert('Recently expired token (<30d) is preserved', EXISTS(SELECT 1 FROM public.email_verifications WHERE id = t_recent));
  PERFORM pg_temp.retention_assert('Used recently expired token (<30d) is preserved', EXISTS(SELECT 1 FROM public.email_verifications WHERE id = t_used_recent));
  PERFORM pg_temp.retention_assert('Token within cutoff (+1s) is preserved', EXISTS(SELECT 1 FROM public.email_verifications WHERE id = t_cutoff_safe));

  -- 5. Test repeated cleanup when no candidates remain
  del_count := public.cleanup_expired_email_verifications(500);
  PERFORM pg_temp.retention_assert('Repeated cleanup with no candidates returns 0', del_count = 0);

  -- 6. Test invalid batch limit parameters
  err_caught := false;
  BEGIN PERFORM public.cleanup_expired_email_verifications(0); EXCEPTION WHEN OTHERS THEN err_caught := true; END;
  PERFORM pg_temp.retention_assert('Batch limit 0 is rejected', err_caught);

  err_caught := false;
  BEGIN PERFORM public.cleanup_expired_email_verifications(-5); EXCEPTION WHEN OTHERS THEN err_caught := true; END;
  PERFORM pg_temp.retention_assert('Negative batch limit is rejected', err_caught);

  err_caught := false;
  BEGIN PERFORM public.cleanup_expired_email_verifications(NULL); EXCEPTION WHEN OTHERS THEN err_caught := true; END;
  PERFORM pg_temp.retention_assert('Null batch limit is rejected', err_caught);

  err_caught := false;
  BEGIN PERFORM public.cleanup_expired_email_verifications(1001); EXCEPTION WHEN OTHERS THEN err_caught := true; END;
  PERFORM pg_temp.retention_assert('Batch limit over 1000 is rejected', err_caught);
  EXECUTE 'RESET ROLE';

  -- 7. Test client execution denial
  FOREACH caller IN ARRAY ARRAY['anon','authenticated'] LOOP
    EXECUTE format('SET LOCAL ROLE %I', caller);
    err_caught := false;
    BEGIN PERFORM public.cleanup_expired_email_verifications(500); EXCEPTION WHEN insufficient_privilege THEN err_caught := true; END;
    PERFORM pg_temp.retention_assert('Public cleanup denied to ' || caller, err_caught);

    err_caught := false;
    BEGIN PERFORM workflow_private.purge_completed_cron_job_runs(500); EXCEPTION WHEN insufficient_privilege THEN err_caught := true; END;
    PERFORM pg_temp.retention_assert('Private cron purge denied to ' || caller, err_caught);

    err_caught := false;
    BEGIN PERFORM workflow_private.run_retention_maintenance(500); EXCEPTION WHEN insufficient_privilege THEN err_caught := true; END;
    PERFORM pg_temp.retention_assert('Private retention runner denied to ' || caller, err_caught);
    EXECUTE 'RESET ROLE';
  END LOOP;

  -- 8. Service role denied from private cron functions
  EXECUTE 'SET LOCAL ROLE service_role';
  err_caught := false;
  BEGIN PERFORM workflow_private.purge_completed_cron_job_runs(500); EXCEPTION WHEN insufficient_privilege THEN err_caught := true; END;
  PERFORM pg_temp.retention_assert('Private cron purge denied to service_role', err_caught);

  err_caught := false;
  BEGIN PERFORM workflow_private.run_retention_maintenance(500); EXCEPTION WHEN insufficient_privilege THEN err_caught := true; END;
  PERFORM pg_temp.retention_assert('Private retention runner denied to service_role', err_caught);
  EXECUTE 'RESET ROLE';

  -- 9. Check function signatures and configurations
  PERFORM pg_temp.retention_assert('Public cleanup is invoker with empty search path',
    (SELECT NOT prosecdef AND provolatile='v' AND proconfig @> ARRAY['search_path=""'] FROM pg_proc WHERE oid='public.cleanup_expired_email_verifications(integer)'::regprocedure));
  PERFORM pg_temp.retention_assert('Private cron purge is definer with empty search path',
    (SELECT prosecdef AND provolatile='v' AND proconfig @> ARRAY['search_path=""'] FROM pg_proc WHERE oid='workflow_private.purge_completed_cron_job_runs(integer)'::regprocedure));
  PERFORM pg_temp.retention_assert('Private runner is definer with empty search path',
    (SELECT prosecdef AND provolatile='v' AND proconfig @> ARRAY['search_path=""'] FROM pg_proc WHERE oid='workflow_private.run_retention_maintenance(integer)'::regprocedure));

  -- 10. Test cron run details retention
  INSERT INTO cron.job_run_details(jobid, command, status, start_time, end_time)
    VALUES (1, 'running job', 'running', statement_timestamp() - interval '40 days', NULL)
    RETURNING runid INTO c_running;

  INSERT INTO cron.job_run_details(jobid, command, status, start_time, end_time)
    VALUES (1, 'recent completed', 'succeeded', statement_timestamp() - interval '10 days', statement_timestamp() - interval '10 days')
    RETURNING runid INTO c_recent;

  INSERT INTO cron.job_run_details(jobid, command, status, start_time, end_time)
    VALUES (1, 'old completed', 'succeeded', statement_timestamp() - interval '35 days', statement_timestamp() - interval '35 days')
    RETURNING runid INTO c_old_succ;

  INSERT INTO cron.job_run_details(jobid, command, status, start_time, end_time)
    VALUES (1, 'old failed', 'failed', statement_timestamp() - interval '40 days', statement_timestamp() - interval '40 days')
    RETURNING runid INTO c_old_fail;

  -- As postgres, run purge
  del_count := workflow_private.purge_completed_cron_job_runs(500);
  PERFORM pg_temp.retention_assert('Purge cron runs deletes completed runs older than 30d', del_count >= 2);
  PERFORM pg_temp.retention_assert('Running cron job (end_time null) preserved', EXISTS(SELECT 1 FROM cron.job_run_details WHERE runid = c_running));
  PERFORM pg_temp.retention_assert('Recent completed run (<30d) preserved', EXISTS(SELECT 1 FROM cron.job_run_details WHERE runid = c_recent));
  PERFORM pg_temp.retention_assert('Old succeeded run (>30d) deleted', NOT EXISTS(SELECT 1 FROM cron.job_run_details WHERE runid = c_old_succ));
  PERFORM pg_temp.retention_assert('Old failed run (>30d) deleted', NOT EXISTS(SELECT 1 FROM cron.job_run_details WHERE runid = c_old_fail));

  -- 11. Test maintenance runner execution
  res := workflow_private.run_retention_maintenance(500);
  PERFORM pg_temp.retention_assert('Maintenance runner executes and reports counts', (res->>'skipped')::boolean IS FALSE AND (res->>'deleted_tokens')::integer >= 0);

END $$;

SELECT * FROM retention_results ORDER BY test;
ROLLBACK;
