-- Migration: 20261012133000_distinguish_authentication_logs_and_activity_views.sql
-- Description: Establishes distinct auth_logs compatibility view over system_logs,
--              revokes anonymous table-level grants from system_logs,
--              and tightens response_log compatibility view permissions.

SET LOCAL lock_timeout = '2s';

-- 1. Revoke unauthenticated access to system authentication logs and audit activity logs
REVOKE ALL ON TABLE public.system_logs FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.system_logs TO authenticated;
GRANT ALL ON TABLE public.system_logs TO service_role;

REVOKE ALL ON TABLE public.audit_logs FROM PUBLIC, anon;
GRANT SELECT, INSERT ON TABLE public.audit_logs TO authenticated;
GRANT ALL ON TABLE public.audit_logs TO service_role;

-- 2. Create secure auth_logs compatibility view for authentication events
CREATE OR REPLACE VIEW public.auth_logs WITH (security_invoker = true) AS
SELECT id, user_id, action_type, action_details, ip_address, user_agent, created_at
FROM public.system_logs;

ALTER VIEW public.auth_logs OWNER TO postgres;
REVOKE ALL ON public.auth_logs FROM PUBLIC, anon;
GRANT SELECT ON public.auth_logs TO authenticated, service_role;

-- 3. Ensure response_log view is strictly scoped
CREATE OR REPLACE VIEW public.response_log WITH (security_invoker = true) AS
SELECT id, report_id, user_id, action_type, action_details, created_at
FROM public.audit_logs;

ALTER VIEW public.response_log OWNER TO postgres;
REVOKE ALL ON public.response_log FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.response_log TO authenticated, service_role;
