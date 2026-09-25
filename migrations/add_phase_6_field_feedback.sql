-- Phase 6: Field Execution and Feedback Loop

-- Add completion result and notes
ALTER TABLE cleanup_tasks 
ADD COLUMN IF NOT EXISTS completion_result TEXT,
ADD COLUMN IF NOT EXISTS completion_notes TEXT;

-- Note: We are using TEXT for status, so we don't need to ALTER TYPE if it's already TEXT.
-- Just in case it's an ENUM, let's try to alter it (will fail harmlessly if it's not an ENUM or if value exists).
-- Since we want this script to be safe, we'll assume it's TEXT or just skip ENUM alters for now, 
-- but let's make sure our application handles these string statuses.
