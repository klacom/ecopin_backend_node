CREATE FUNCTION public.complete_email_verification(p_verification_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = ''
AS $function$
DECLARE verification public.email_verifications%ROWTYPE; matched_profile uuid;
BEGIN
  -- Serialize redemption, then check expiry after any lock wait.
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