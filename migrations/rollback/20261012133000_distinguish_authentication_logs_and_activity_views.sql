-- Rollback: 20261012133000_distinguish_authentication_logs_and_activity_views.sql
-- Description: Reverts auth_logs view and restores baseline grants.

SET LOCAL lock_timeout = '2s';

DROP VIEW IF EXISTS public.auth_logs;

GRANT ALL ON TABLE public.system_logs TO anon, authenticated, service_role;
GRANT ALL ON TABLE public.audit_logs TO anon, authenticated, service_role;
