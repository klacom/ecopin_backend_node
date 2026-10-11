ALTER TABLE public.email_verifications ADD COLUMN IF NOT EXISTS token_digest text;
ALTER TABLE public.email_verifications ALTER COLUMN token DROP NOT NULL;
ALTER TABLE public.email_verifications ALTER COLUMN token DROP DEFAULT;
DO $$ BEGIN
  IF NOT EXISTS(SELECT FROM pg_catalog.pg_constraint WHERE conrelid='public.email_verifications'::regclass AND conname='email_verifications_digest_format') THEN
    ALTER TABLE public.email_verifications ADD CONSTRAINT email_verifications_digest_format
      CHECK (token_digest IS NULL OR (token IS NULL AND token_digest ~ '^[0-9a-f]{64}$'));
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS email_verifications_token_digest_unique ON public.email_verifications(token_digest) WHERE token_digest IS NOT NULL;
REVOKE ALL ON TABLE public.email_verifications FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.issue_email_verification(p_user_id uuid,p_token_digest text,p_ttl_hours integer DEFAULT 24)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=''
AS $function$
DECLARE profile public.profiles%ROWTYPE; issuance_id uuid;
BEGIN
  IF p_token_digest IS NULL OR p_token_digest !~ '^[0-9a-f]{64}$'
     OR p_ttl_hours IS NULL OR p_ttl_hours<1 OR p_ttl_hours>24 THEN
    RAISE EXCEPTION 'Invalid verification issuance parameters' USING ERRCODE='22023';
  END IF;
  -- This profile lock serializes issuance across all application processes.
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