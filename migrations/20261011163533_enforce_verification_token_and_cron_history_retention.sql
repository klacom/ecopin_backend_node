-- Bounded cleanup for expired email verification tokens (>30d).
-- SECURITY INVOKER ensures execution is governed by caller table privileges (postgres and service_role).
CREATE OR REPLACE FUNCTION public.cleanup_expired_email_verifications(p_batch_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
SET statement_timeout = '15s'
SET lock_timeout = '2s'
AS $$
DECLARE
  v_cutoff timestamptz;
  v_deleted integer := 0;
BEGIN
  IF p_batch_limit IS NULL OR p_batch_limit < 1 OR p_batch_limit > 1000 THEN
    RAISE EXCEPTION 'Batch limit must be between 1 and 1000';
  END IF;

  v_cutoff := statement_timestamp() - interval '30 days';

  WITH candidates AS (
    SELECT id
    FROM public.email_verifications
    WHERE expires_at <= v_cutoff
    ORDER BY expires_at ASC, id ASC
    LIMIT p_batch_limit
    FOR UPDATE SKIP LOCKED
  ),
  removed AS (
    DELETE FROM public.email_verifications v
    USING candidates c
    WHERE v.id = c.id
    RETURNING v.id
  )
  SELECT count(*)::integer INTO v_deleted FROM removed;

  RETURN v_deleted;
END;
$$;
ALTER FUNCTION public.cleanup_expired_email_verifications(integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.cleanup_expired_email_verifications(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_email_verifications(integer) TO service_role, postgres;

-- Bounded purge for completed cron job run details (>30d).
-- Private to postgres; service_role, anon, and authenticated are denied.
CREATE OR REPLACE FUNCTION workflow_private.purge_completed_cron_job_runs(p_batch_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET statement_timeout = '15s'
SET lock_timeout = '2s'
AS $$
DECLARE
  v_cutoff timestamptz;
  v_deleted integer := 0;
BEGIN
  IF p_batch_limit IS NULL OR p_batch_limit < 1 OR p_batch_limit > 1000 THEN
    RAISE EXCEPTION 'Batch limit must be between 1 and 1000';
  END IF;

  v_cutoff := statement_timestamp() - interval '30 days';

  WITH candidates AS (
    SELECT runid
    FROM cron.job_run_details
    WHERE end_time IS NOT NULL
      AND status IN ('succeeded', 'failed')
      AND end_time <= v_cutoff
    ORDER BY end_time ASC, runid ASC
    LIMIT p_batch_limit
    FOR UPDATE SKIP LOCKED
  ),
  removed AS (
    DELETE FROM cron.job_run_details j
    USING candidates c
    WHERE j.runid = c.runid
    RETURNING j.runid
  )
  SELECT count(*)::integer INTO v_deleted FROM removed;

  RETURN v_deleted;
END;
$$;
ALTER FUNCTION workflow_private.purge_completed_cron_job_runs(integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION workflow_private.purge_completed_cron_job_runs(integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION workflow_private.purge_completed_cron_job_runs(integer) TO postgres;

-- Maintenance runner invoked by pg_cron.
CREATE OR REPLACE FUNCTION workflow_private.run_retention_maintenance(p_batch_limit integer DEFAULT 500)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET statement_timeout = '30s'
SET lock_timeout = '2s'
AS $$
DECLARE
  v_tokens integer := 0;
  v_runs integer := 0;
BEGIN
  IF NOT pg_catalog.pg_try_advisory_xact_lock(72631017) THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'advisory_lock_held');
  END IF;

  v_tokens := public.cleanup_expired_email_verifications(p_batch_limit);
  v_runs := workflow_private.purge_completed_cron_job_runs(p_batch_limit);

  RETURN jsonb_build_object(
    'skipped', false,
    'deleted_tokens', v_tokens,
    'deleted_cron_runs', v_runs
  );
END;
$$;
ALTER FUNCTION workflow_private.run_retention_maintenance(integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION workflow_private.run_retention_maintenance(integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION workflow_private.run_retention_maintenance(integer) TO postgres;

-- Hourly cron schedule at minute 39 (avoids collisions with minute 0 lifecycle and minute % 5 watchdog).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ecopin-retention-maintenance') THEN
    PERFORM cron.unschedule('ecopin-retention-maintenance');
  END IF;
  PERFORM cron.schedule('ecopin-retention-maintenance', '39 * * * *', 'SELECT workflow_private.run_retention_maintenance();');
END $$;
