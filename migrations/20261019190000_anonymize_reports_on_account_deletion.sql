-- Migration: 20261019190000_anonymize_reports_on_account_deletion.sql
-- Enforces ON DELETE SET NULL on reports.user_id foreign key so that citizen account
-- deletion preserves municipal waste reports and public statistics in an anonymized state.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'reports_user_id_fkey'
      AND conrelid = 'reports'::regclass
  ) THEN
    ALTER TABLE reports DROP CONSTRAINT reports_user_id_fkey;
  END IF;

  ALTER TABLE reports
    ADD CONSTRAINT reports_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES profiles(id)
    ON DELETE SET NULL;
END $$;
