BEGIN;
SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='20s';
CREATE SCHEMA IF NOT EXISTS verification_private;
REVOKE ALL ON SCHEMA verification_private FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA verification_private TO service_role;

CREATE OR REPLACE FUNCTION verification_private.redeem_email(
 p_verification_id uuid,p_user_id uuid,p_expected_email text
) RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=''
AS $function$
DECLARE account auth.users%ROWTYPE; verification public.email_verifications%ROWTYPE;
BEGIN
 -- No HTTP calls under locks. NO KEY UPDATE permits concurrent FK checks.
 SELECT * INTO account FROM auth.users WHERE id=p_user_id FOR NO KEY UPDATE;
 IF NOT FOUND THEN RETURN false; END IF;
 PERFORM 1 FROM public.profiles WHERE id=p_user_id FOR UPDATE;
 SELECT * INTO verification FROM public.email_verifications
 WHERE id=p_verification_id AND user_id=p_user_id FOR UPDATE;
 IF NOT FOUND OR verification.used_at IS NOT NULL
   OR verification.expires_at IS NULL OR verification.created_at IS NULL
   OR verification.issued_to_email IS NULL
   OR pg_catalog.lower(pg_catalog.btrim(account.email)) IS DISTINCT FROM verification.issued_to_email
   OR pg_catalog.lower(pg_catalog.btrim(p_expected_email)) IS DISTINCT FROM verification.issued_to_email THEN RETURN false; END IF;
 -- Recover an old partial completion only when Auth recorded confirmation
 -- inside this bound token's validity window. Expiry cannot authorize new confirmation.
 IF verification.expires_at<=pg_catalog.clock_timestamp() AND NOT (
   account.email_confirmed_at IS NOT NULL
   AND account.email_confirmed_at>=verification.created_at
   AND account.email_confirmed_at<=verification.expires_at
 ) THEN RETURN false; END IF;
 IF account.email_confirmed_at IS NULL THEN
   -- Match GoTrue v2.197.0 User.Confirm semantics for this custom-email flow.
   UPDATE auth.users SET email_confirmed_at=pg_catalog.clock_timestamp(),
     confirmation_token='',updated_at=pg_catalog.clock_timestamp(),
     raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)||'{"email_verified":true}'::jsonb
   WHERE id=p_user_id;
   DELETE FROM auth.one_time_tokens WHERE user_id=p_user_id;
 END IF;
 INSERT INTO public.profiles(id,full_name,role,is_email_verified)
 VALUES(p_user_id,coalesce(account.email,'Citizen'),'citizen',true)
 ON CONFLICT(id) DO UPDATE SET is_email_verified=true;
 UPDATE public.email_verifications SET used_at=pg_catalog.clock_timestamp() WHERE id=p_verification_id;
 RETURN true;
END;
$function$;
REVOKE ALL ON FUNCTION verification_private.redeem_email(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION verification_private.redeem_email(uuid,uuid,text) TO service_role;

CREATE OR REPLACE FUNCTION public.redeem_email_verification_atomic(
 p_verification_id uuid,p_user_id uuid,p_expected_email text
) RETURNS boolean LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path=''
AS $function$
 SELECT verification_private.redeem_email(p_verification_id,p_user_id,p_expected_email);
$function$;
REVOKE ALL ON FUNCTION public.redeem_email_verification_atomic(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_email_verification_atomic(uuid,uuid,text) TO service_role;
COMMIT;
