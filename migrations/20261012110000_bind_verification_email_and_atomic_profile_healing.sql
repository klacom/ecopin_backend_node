-- Migration: 20261012110000_bind_verification_email_and_atomic_profile_healing.sql
-- Description: Adds issued_to_email to public.email_verifications, binds token redemption
--              to matching email address, self-heals missing profile records, and ensures
--              robust Auth/DB error recovery.

SET LOCAL lock_timeout = '2s';

ALTER TABLE public.email_verifications ADD COLUMN IF NOT EXISTS issued_to_email text;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_constraint 
    WHERE conrelid = 'public.email_verifications'::regclass 
      AND conname = 'email_verifications_issued_email_format'
  ) THEN
    ALTER TABLE public.email_verifications ADD CONSTRAINT email_verifications_issued_email_format
      CHECK (issued_to_email IS NULL OR (pg_catalog.length(issued_to_email) <= 320 AND issued_to_email ~ '^[^\s@]+@[^\s@]+$'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.issue_email_verification(
  p_user_id uuid,
  p_token_digest text,
  p_ttl_hours integer,
  p_email text
)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=''
AS $function$
DECLARE 
  profile public.profiles%ROWTYPE; 
  issuance_id uuid; 
  clean_email text := NULL;
BEGIN
  IF p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$'
     OR p_ttl_hours IS NULL OR p_ttl_hours < 1 OR p_ttl_hours > 24 THEN
    RAISE EXCEPTION 'Invalid verification issuance parameters' USING ERRCODE='22023';
  END IF;

  IF p_email IS NOT NULL THEN
    clean_email := pg_catalog.lower(pg_catalog.btrim(p_email));
    IF pg_catalog.length(clean_email) > 320 OR clean_email !~ '^[^\s@]+@[^\s@]+$' THEN
      RAISE EXCEPTION 'Invalid verification email parameter' USING ERRCODE='22023';
    END IF;
  END IF;

  -- This profile lock serializes issuance across all application processes.
  SELECT * INTO profile FROM public.profiles WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND OR profile.is_email_verified IS TRUE THEN RETURN NULL; END IF;
  IF EXISTS(SELECT FROM public.email_verifications WHERE user_id = p_user_id
      AND created_at > pg_catalog.clock_timestamp() - interval '60 seconds') THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.email_verifications(user_id, token, token_digest, issued_to_email, expires_at, created_at)
  VALUES(p_user_id, NULL, p_token_digest, clean_email, pg_catalog.clock_timestamp() + pg_catalog.make_interval(hours => p_ttl_hours), pg_catalog.clock_timestamp())
  RETURNING id INTO issuance_id;
  RETURN issuance_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.issue_email_verification(
  p_user_id uuid,
  p_token_digest text,
  p_ttl_hours integer DEFAULT 24
)
RETURNS uuid LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path=''
AS $function$
  SELECT public.issue_email_verification(p_user_id, p_token_digest, p_ttl_hours, NULL::text);
$function$;

REVOKE ALL ON FUNCTION public.issue_email_verification(uuid,text,integer,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.issue_email_verification(uuid,text,integer,text) TO service_role;
REVOKE ALL ON FUNCTION public.issue_email_verification(uuid,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.issue_email_verification(uuid,text,integer) TO service_role;

CREATE OR REPLACE FUNCTION public.complete_email_verification(
  p_verification_id uuid,
  p_user_id uuid,
  p_expected_email text
)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = ''
AS $function$
DECLARE 
  verification public.email_verifications%ROWTYPE; 
  matched_profile uuid;
  clean_expected text := NULL;
BEGIN
  -- Serialize redemption, then check expiry after any lock wait.
  SELECT * INTO verification FROM public.email_verifications
  WHERE id = p_verification_id AND user_id = p_user_id FOR UPDATE;
  IF NOT FOUND OR verification.used_at IS NOT NULL
     OR verification.expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN false;
  END IF;

  -- Validate bound email address if recorded
  IF verification.issued_to_email IS NOT NULL THEN
    IF p_expected_email IS NULL THEN
      RETURN false;
    END IF;
    clean_expected := pg_catalog.lower(pg_catalog.btrim(p_expected_email));
    IF clean_expected <> verification.issued_to_email THEN
      RETURN false;
    END IF;
  END IF;

  -- Atomic update of profile with self-healing fallback
  UPDATE public.profiles SET is_email_verified = true
  WHERE id = verification.user_id RETURNING id INTO matched_profile;
  
  IF NOT FOUND THEN
    INSERT INTO public.profiles (id, full_name, role, is_email_verified)
    VALUES (verification.user_id, coalesce(clean_expected, 'Citizen'), 'citizen', true)
    ON CONFLICT (id) DO UPDATE SET is_email_verified = true
    RETURNING id INTO matched_profile;
  END IF;

  IF matched_profile IS NULL THEN 
    RETURN false; 
  END IF;

  UPDATE public.email_verifications SET used_at = pg_catalog.clock_timestamp()
  WHERE id = verification.id;
  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.complete_email_verification(
  p_verification_id uuid,
  p_user_id uuid
)
RETURNS boolean LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path=''
AS $function$
  SELECT public.complete_email_verification(p_verification_id, p_user_id, NULL::text);
$function$;

REVOKE ALL ON FUNCTION public.complete_email_verification(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.complete_email_verification(uuid,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION public.complete_email_verification(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.complete_email_verification(uuid,uuid) TO service_role;
