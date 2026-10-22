DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ecopin-retention-maintenance') THEN
    PERFORM cron.unschedule('ecopin-retention-maintenance');
  END IF;
END $$;

DROP FUNCTION IF EXISTS workflow_private.run_retention_maintenance(integer);
DROP FUNCTION IF EXISTS workflow_private.purge_completed_cron_job_runs(integer);
DROP FUNCTION IF EXISTS public.cleanup_expired_email_verifications(integer);
