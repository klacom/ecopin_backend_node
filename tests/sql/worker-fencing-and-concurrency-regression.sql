BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '2s';

CREATE TEMP TABLE w05_results(test text, status text, detail text) ON COMMIT DROP;
GRANT INSERT, SELECT ON w05_results TO anon, authenticated, service_role;

CREATE FUNCTION pg_temp.w05_assert(label text, condition boolean, detail text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO w05_results VALUES(label, CASE WHEN condition IS TRUE THEN 'PASS' ELSE 'FAIL' END, coalesce(detail, ''));
END;
$$;

DO $$
DECLARE
  v_admin_id uuid;
  v_worker_a uuid := gen_random_uuid();
  v_worker_b uuid := gen_random_uuid();
  v_worker_c uuid := gen_random_uuid();
  v_job_id uuid;
  v_job_record jsonb;
  v_claim_a jsonb;
  v_claim_b jsonb;
  v_stale_finish_err text := '';
  v_post_expire_finish_err text := '';
  v_job_final public.plan_generation_jobs;
BEGIN
  SELECT id INTO v_admin_id FROM public.profiles WHERE role::text='admin' LIMIT 1;
  IF v_admin_id IS NULL THEN
    SELECT id INTO v_admin_id FROM public.profiles LIMIT 1;
  END IF;

  -- 1. Enqueue job
  v_job_record := public.enqueue_plan_generation(
    v_admin_id, 
    'standard', 
    '{"mode":"standard"}'::jsonb, 
    'w05-fencing-test-' || gen_random_uuid()::text
  );
  v_job_id := (v_job_record->>'jobId')::uuid;

  -- 2. Worker A claims job
  v_claim_a := public.claim_plan_generation(v_worker_a);
  PERFORM pg_temp.w05_assert(
    'Worker A claims queued job exclusively',
    v_claim_a->>'id' = v_job_id::text AND v_claim_a->>'worker_token' = v_worker_a::text,
    'Claimed token=' || coalesce(v_claim_a->>'worker_token', 'null')
  );

  -- 3. Concurrent Worker B tries to claim (no other queued jobs exist)
  v_claim_b := public.claim_plan_generation(v_worker_b);
  PERFORM pg_temp.w05_assert(
    'Concurrent Worker B receives null when queue is empty',
    v_claim_b IS NULL,
    'Worker B claim=' || coalesce(v_claim_b::text, 'null')
  );

  -- 4. Stranger Worker C tries to finish Worker A's job -> must be rejected
  BEGIN
    PERFORM public.finish_plan_generation(v_job_id, v_worker_c, NULL, 'worker_failure');
  EXCEPTION WHEN OTHERS THEN
    v_stale_finish_err := SQLERRM;
  END;
  PERFORM pg_temp.w05_assert(
    'Stranger Worker C is rejected from finishing active job',
    v_stale_finish_err LIKE '%Planning job lease expired%',
    'Error=' || v_stale_finish_err
  );

  -- 5. Simulate Worker A crashing and lease expiring
  UPDATE public.plan_generation_jobs
  SET lease_until = now() - interval '10 seconds'
  WHERE id = v_job_id;

  -- 6. Another worker checks for work -> crashed job is detected and failed with 'worker_lease_expired'
  PERFORM public.claim_plan_generation(v_worker_b);

  SELECT * INTO v_job_final FROM public.plan_generation_jobs WHERE id = v_job_id;
  PERFORM pg_temp.w05_assert(
    'Crashed worker job is recovered with worker_lease_expired',
    v_job_final.status = 'failed' AND v_job_final.error_code = 'worker_lease_expired',
    'Status=' || v_job_final.status || ', Error=' || coalesce(v_job_final.error_code, 'none')
  );

  -- 7. Stale Worker A wakes up and tries to finish the job -> must be rejected
  BEGIN
    PERFORM public.finish_plan_generation(v_job_id, v_worker_a, NULL, 'late_failure');
  EXCEPTION WHEN OTHERS THEN
    v_post_expire_finish_err := SQLERRM;
  END;
  PERFORM pg_temp.w05_assert(
    'Expired Worker A is rejected from finishing recovered job',
    v_post_expire_finish_err LIKE '%Planning job lease expired%',
    'Error=' || v_post_expire_finish_err
  );

  -- Self-cleaning fixture teardown
  DELETE FROM public.plan_generation_jobs WHERE id = v_job_id;
END $$;

SELECT test, status, detail FROM w05_results;
COMMIT;
