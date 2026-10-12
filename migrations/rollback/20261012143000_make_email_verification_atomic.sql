BEGIN;
SET LOCAL lock_timeout='2s';
DROP FUNCTION IF EXISTS public.redeem_email_verification_atomic(uuid,uuid,text);
DROP FUNCTION IF EXISTS verification_private.redeem_email(uuid,uuid,text);
-- Never unconfirm accounts or undo consumed tokens during rollback.
-- The new backend fails closed with 503 while this RPC is absent.
-- Reapply the migration to restore service; restore a matching backend only
-- after assessing the older implementation's known email-change race.
COMMIT;
