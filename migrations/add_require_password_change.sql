-- Add require_password_change column to profiles
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS require_password_change BOOLEAN DEFAULT false;
