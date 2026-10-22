-- Preserve digest rows and schema: digests cannot recover their delivered secrets.
-- Revert backend callers first. Legacy callers can issue a new raw UUID link;
-- links issued through the digest flow require the digest-aware backend or resend.
DROP FUNCTION public.issue_email_verification(uuid,text,integer);
-- Intentionally retain client privilege revocation, storage columns and index.
