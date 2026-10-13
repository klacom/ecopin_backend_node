-- 20261013162000_drop_overloaded_claim_plan_generation.sql
-- Drops obsolete single-argument public.claim_plan_generation(uuid) to eliminate PostgREST HTTP 300 Multiple Choices

DROP FUNCTION IF EXISTS public.claim_plan_generation(uuid);

-- Ensure execute permissions on canonical two-argument function
REVOKE ALL ON FUNCTION public.claim_plan_generation(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_plan_generation(uuid, text) TO authenticated, service_role;
