-- The private reader exposes only an eligible UUID, never Auth metadata.
CREATE OR REPLACE FUNCTION workflow_private.find_email_verification_user(p_email text)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=''
AS $$
DECLARE address text; candidates uuid[];
BEGIN
  IF p_email IS NULL OR length(p_email)>320 THEN RETURN NULL; END IF;
  address:=lower(btrim(p_email));
  IF length(address) NOT BETWEEN 3 AND 254 OR address !~ '^[^[:space:]@]+@[^[:space:]@]+$' THEN
    RETURN NULL;
  END IF;
  -- Keep equality on the indexed Auth email column; two rows prove ambiguity.
  SELECT array_agg(candidate.id) INTO candidates
  FROM (SELECT u.id FROM auth.users u WHERE u.email=address LIMIT 2) candidate;
  IF cardinality(candidates) IS DISTINCT FROM 1 THEN RETURN NULL; END IF;
  IF EXISTS(SELECT FROM public.profiles p WHERE p.id=candidates[1] AND p.is_email_verified IS DISTINCT FROM true) THEN
    RETURN candidates[1];
  END IF;
  RETURN NULL;
END $$;
ALTER FUNCTION workflow_private.find_email_verification_user(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION workflow_private.find_email_verification_user(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION workflow_private.find_email_verification_user(text) TO service_role;

CREATE OR REPLACE FUNCTION public.find_email_verification_user(p_email text)
RETURNS uuid LANGUAGE sql STABLE SECURITY INVOKER SET search_path=''
AS $$ SELECT workflow_private.find_email_verification_user(p_email); $$;
REVOKE ALL ON FUNCTION public.find_email_verification_user(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.find_email_verification_user(text) TO service_role;