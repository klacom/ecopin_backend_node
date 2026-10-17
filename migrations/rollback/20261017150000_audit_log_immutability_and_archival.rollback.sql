-- Rollback Migration: 20261017150000_audit_log_immutability_and_archival.rollback.sql
-- Description: Reverts audit log immutability triggers and trigger function.

SET LOCAL lock_timeout = '3s';

DROP TRIGGER IF EXISTS trg_audit_logs_immutable ON public.audit_logs;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'sweeper_audit_log') THEN
    DROP TRIGGER IF EXISTS trg_sweeper_audit_log_immutable ON public.sweeper_audit_log;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'system_logs') THEN
    DROP TRIGGER IF EXISTS trg_system_logs_immutable ON public.system_logs;
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.prevent_audit_modification();
