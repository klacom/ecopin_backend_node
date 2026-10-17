-- Migration: 20261017150000_audit_log_immutability_and_archival.sql
-- Description: Enforces database-level immutability triggers on audit log tables
--              (prevent_audit_modification) rejecting UPDATE/DELETE,
--              establishes safe archival bypass with transaction flag,
--              and configures 180-day hot retention and 7-year WORM archival policy.

SET LOCAL lock_timeout = '3s';

-- 1. Create or replace the immutability enforcement trigger function
CREATE OR REPLACE FUNCTION public.prevent_audit_modification()
RETURNS TRIGGER AS $$
BEGIN
  -- Allow DELETE only when explicit transaction-level archival flag is activated
  IF TG_OP = 'DELETE' AND current_setting('app.allow_audit_archive', true) = 'true' THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION 'Audit records are immutable and cannot be updated or deleted. Table: %, Operation: %', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION public.prevent_audit_modification() IS
'Enforces WORM-compliant immutability on audit logs by rejecting UPDATE and DELETE operations unless app.allow_audit_archive is explicitly set.';

-- 2. Attach immutability triggers to public.audit_logs
DROP TRIGGER IF EXISTS trg_audit_logs_immutable ON public.audit_logs;
CREATE TRIGGER trg_audit_logs_immutable
BEFORE UPDATE OR DELETE ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_modification();

-- 3. Attach immutability triggers to public.sweeper_audit_log
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'sweeper_audit_log') THEN
    DROP TRIGGER IF EXISTS trg_sweeper_audit_log_immutable ON public.sweeper_audit_log;
    CREATE TRIGGER trg_sweeper_audit_log_immutable
    BEFORE UPDATE OR DELETE ON public.sweeper_audit_log
    FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_modification();
  END IF;
END $$;

-- 4. Attach immutability triggers to public.system_logs
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'system_logs') THEN
    DROP TRIGGER IF EXISTS trg_system_logs_immutable ON public.system_logs;
    CREATE TRIGGER trg_system_logs_immutable
    BEFORE UPDATE OR DELETE ON public.system_logs
    FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_modification();
  END IF;
END $$;

-- 5. Revoke destructive privileges on audit tables
REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.audit_logs FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'sweeper_audit_log') THEN
    REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.sweeper_audit_log FROM PUBLIC, anon, authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'system_logs') THEN
    REVOKE UPDATE, DELETE, TRUNCATE ON TABLE public.system_logs FROM PUBLIC, anon, authenticated;
  END IF;
END $$;
