-- Rollback migration: 20261012110000_bind_verification_email_and_atomic_profile_healing.sql

SET LOCAL lock_timeout = '2s';

DROP FUNCTION IF EXISTS public.complete_email_verification(uuid,uuid,text);
CREATE OR REPLACE FUNCTION public.complete_email_verification(p_verification_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = ''
AS $function$
DECLARE verification public.email_verifications%ROWTYPE; matched_profile uuid;
BEGIN
  SELECT * INTO verification FROM public.email_verifications
  WHERE id = p_verification_id AND user_id = p_user_id FOR UPDATE;
  IF NOT FOUND OR verification.used_at IS NOT NULL
     OR verification.expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN false;
  END IF;

  UPDATE public.profiles SET is_email_verified = true
  WHERE id = verification.user_id RETURNING id INTO matched_profile;
  IF NOT FOUND THEN RETURN false; END IF;

  UPDATE public.email_verifications SET used_at = pg_catalog.clock_timestamp()
  WHERE id = verification.id;
  RETURN true;
END;
$function$;
REVOKE ALL ON FUNCTION public.complete_email_verification(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.complete_email_verification(uuid,uuid) TO service_role;

DROP FUNCTION IF EXISTS public.issue_email_verification(uuid,text,integer,text);
CREATE OR REPLACE FUNCTION public.issue_email_verification(p_user_id uuid,p_token_digest text,p_ttl_hours integer DEFAULT 24)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=''
AS $function$
DECLARE profile public.profiles%ROWTYPE; issuance_id uuid;
BEGIN
  IF p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$'
     OR p_ttl_hours IS NULL OR p_ttl_hours<1 OR p_ttl_hours>24 THEN
    RAISE EXCEPTION 'Invalid verification issuance parameters' USING ERRCODE='22023';
  END IF;
  SELECT * INTO profile FROM public.profiles WHERE id=p_user_id FOR UPDATE;
  IF NOT FOUND OR profile.is_email_verified IS TRUE THEN RETURN NULL; END IF;
  IF EXISTS(SELECT FROM public.email_verifications WHERE user_id=p_user_id
      AND created_at>pg_catalog.clock_timestamp()-interval '60 seconds') THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.email_verifications(user_id,token,token_digest,expires_at,created_at)
  VALUES(p_user_id,NULL,p_token_digest,pg_catalog.clock_timestamp()+pg_catalog.make_interval(hours=>p_ttl_hours),pg_catalog.clock_timestamp())
  RETURNING id INTO issuance_id;
  RETURN issuance_id;
END;
$function$;
REVOKE ALL ON FUNCTION public.issue_email_verification(uuid,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.issue_email_verification(uuid,text,integer) TO service_role;

ALTER TABLE public.email_verifications DROP CONSTRAINT IF EXISTS email_verifications_issued_email_format;
ALTER TABLE public.email_verifications DROP COLUMN IF EXISTS issued_to_email;
