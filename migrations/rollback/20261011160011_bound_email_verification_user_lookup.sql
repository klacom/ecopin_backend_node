-- Revert the resend controller first; otherwise resend safely stops issuing.
DROP FUNCTION IF EXISTS public.find_email_verification_user(text);
DROP FUNCTION IF EXISTS workflow_private.find_email_verification_user(text);
-- No Auth table, data, existing schema privileges or managed indexes are changed.
