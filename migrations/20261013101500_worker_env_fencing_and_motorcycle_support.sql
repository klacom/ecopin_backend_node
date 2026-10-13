-- 20261013101500_worker_env_fencing_and_motorcycle_support.sql
-- Fences plan_generation_jobs claims so external or older workers do not claim development jobs or unsupported travel modes (such as MOTORCYCLE).

CREATE OR REPLACE FUNCTION public.claim_plan_generation(
  worker_id uuid,
  worker_env text DEFAULT 'production'
)
RETURNS SETOF public.plan_generation_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_job public.plan_generation_jobs;
BEGIN
  SELECT *
  INTO v_job
  FROM public.plan_generation_jobs
  WHERE status = 'pending'
    AND (
      (worker_env = 'development')
      OR (
        COALESCE(settings->>'environment', 'production') = 'production'
        AND COALESCE(settings->>'travel_mode', '') != 'MOTORCYCLE'
      )
    )
  ORDER BY created_at ASC
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF FOUND THEN
    UPDATE public.plan_generation_jobs
    SET status = 'processing',
        started_at = clock_timestamp(),
        claimed_by = worker_id,
        updated_at = clock_timestamp()
    WHERE id = v_job.id
    RETURNING * INTO v_job;

    RETURN NEXT v_job;
  END IF;

  RETURN;
END;
$$;
