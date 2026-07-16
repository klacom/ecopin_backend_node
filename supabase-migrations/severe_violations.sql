-- Add severe violation categories and handling
-- This migration adds support for handling severe content violations differently

-- Create enum type for violation severity levels
CREATE TYPE violation_severity AS ENUM ('normal', 'severe');

-- Create enum type for severe violation categories
CREATE TYPE severe_violation_category AS ENUM (
    'nudity',
    'pornography',
    'graphic_violence',
    'gore',
    'terrorism',
    'hate_symbols'
);

-- Add severity and category columns to strikes table
ALTER TABLE strikes ADD COLUMN IF NOT EXISTS severity violation_severity DEFAULT 'normal';
ALTER TABLE strikes ADD COLUMN IF NOT EXISTS severe_category severe_violation_category;
ALTER TABLE strikes ADD COLUMN IF NOT EXISTS requires_manual_review BOOLEAN DEFAULT false;
ALTER TABLE strikes ADD COLUMN IF NOT EXISTS manual_review_status VARCHAR(50); -- 'pending', 'reviewed', 'dismissed'

-- Create index on severity for faster queries
CREATE INDEX IF NOT EXISTS idx_strikes_severity ON strikes(severity);
CREATE INDEX IF NOT EXISTS idx_strikes_manual_review ON strikes(requires_manual_review, manual_review_status);

-- Add comments
COMMENT ON COLUMN strikes.severity IS 'Severity level of the violation (normal or severe)';
COMMENT ON COLUMN strikes.severe_category IS 'Category of severe violation (if applicable)';
COMMENT ON COLUMN strikes.requires_manual_review IS 'Whether this strike requires manual review';
COMMENT ON COLUMN strikes.manual_review_status IS 'Status of manual review (pending, reviewed, dismissed)';

-- Add severe violation handling to system_settings
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS severe_violation_action VARCHAR(50) DEFAULT 'suspend_7d';
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS severe_violation_duration_hours INTEGER DEFAULT 168; -- 7 days
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS severe_violation_auto_reject BOOLEAN DEFAULT true;
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS severe_violation_immediate_strike BOOLEAN DEFAULT true;

-- Add comments to new system_settings columns
COMMENT ON COLUMN system_settings.severe_violation_action IS 'Action for severe violations (warning, suspend_24h, suspend_7d, permanent_ban)';
COMMENT ON COLUMN system_settings.severe_violation_duration_hours IS 'Duration in hours for severe violation suspension';
COMMENT ON COLUMN system_settings.severe_violation_auto_reject IS 'Whether to automatically reject reports with severe violations';
COMMENT ON COLUMN system_settings.severe_violation_immediate_strike IS 'Whether to immediately issue a strike for severe violations';

-- Update default settings with severe violation configuration
UPDATE system_settings SET
    severe_violation_action = 'suspend_7d',
    severe_violation_duration_hours = 168,
    severe_violation_auto_reject = true,
    severe_violation_immediate_strike = true
WHERE id IS NOT NULL;

-- Add manual review queue table
CREATE TABLE IF NOT EXISTS manual_review_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID REFERENCES reports(id) ON DELETE CASCADE,
    strike_id UUID REFERENCES strikes(id) ON DELETE SET NULL,
    review_type VARCHAR(50) NOT NULL, -- 'severe_violation', 'appeal', 'other'
    priority VARCHAR(20) DEFAULT 'normal', -- 'low', 'normal', 'high', 'urgent'
    status VARCHAR(50) DEFAULT 'pending', -- 'pending', 'in_review', 'approved', 'rejected', 'dismissed'
    assigned_to UUID REFERENCES profiles(id) ON DELETE SET NULL,
    assigned_at TIMESTAMP WITH TIME ZONE,
    reviewed_at TIMESTAMP WITH TIME ZONE,
    review_notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now())
);

-- Create indexes for manual review queue
CREATE INDEX IF NOT EXISTS idx_manual_review_queue_status ON manual_review_queue(status);
CREATE INDEX IF NOT EXISTS idx_manual_review_queue_priority ON manual_review_queue(priority);
CREATE INDEX IF NOT EXISTS idx_manual_review_queue_assigned_to ON manual_review_queue(assigned_to);
CREATE INDEX IF NOT EXISTS idx_manual_review_queue_report_id ON manual_review_queue(report_id);

-- Add RLS policies for manual review queue
ALTER TABLE manual_review_queue ENABLE ROW LEVEL SECURITY;

-- Allow admins to view all review items
CREATE POLICY "Allow admins to view manual review queue"
    ON manual_review_queue FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role IN ('admin', 'lgu')
        )
    );

-- Allow admins to insert review items
CREATE POLICY "Allow admins to insert manual review queue"
    ON manual_review_queue FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role IN ('admin', 'lgu')
        )
    );

-- Allow admins to update review items
CREATE POLICY "Allow admins to update manual review queue"
    ON manual_review_queue FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role IN ('admin', 'lgu')
        )
    );

-- Allow admins to delete review items
CREATE POLICY "Allow admins to delete manual review queue"
    ON manual_review_queue FOR DELETE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role IN ('admin', 'lgu')
        )
    );

-- Add comments to manual review queue
COMMENT ON TABLE manual_review_queue IS 'Queue for items requiring manual review by administrators';
COMMENT ON COLUMN manual_review_queue.report_id IS 'Associated report (if applicable)';
COMMENT ON COLUMN manual_review_queue.strike_id IS 'Associated strike (if applicable)';
COMMENT ON COLUMN manual_review_queue.review_type IS 'Type of review needed';
COMMENT ON COLUMN manual_review_queue.priority IS 'Priority level of the review';
COMMENT ON COLUMN manual_review_queue.status IS 'Current status of the review';
COMMENT ON COLUMN manual_review_queue.assigned_to IS 'Admin assigned to review this item';
COMMENT ON COLUMN manual_review_queue.assigned_at IS 'When the item was assigned';
COMMENT ON COLUMN manual_review_queue.reviewed_at IS 'When the review was completed';
COMMENT ON COLUMN manual_review_queue.review_notes IS 'Notes from the reviewer';

-- Create trigger to update updated_at timestamp
CREATE TRIGGER update_manual_review_queue_updated_at
    BEFORE UPDATE ON manual_review_queue
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Add flag to reports for severe violations
ALTER TABLE reports ADD COLUMN IF NOT EXISTS flagged_severe BOOLEAN DEFAULT false;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS severe_violation_category severe_violation_category;
ALTER TABLE reports ADD COLUMN IF NOT EXISTS manual_review_id UUID REFERENCES manual_review_queue(id) ON DELETE SET NULL;

-- Create index on flagged_severe
CREATE INDEX IF NOT EXISTS idx_reports_flagged_severe ON reports(flagged_severe);

-- Add comments to reports columns
COMMENT ON COLUMN reports.flagged_severe IS 'Whether this report was flagged for severe content violations';
COMMENT ON COLUMN reports.severe_violation_category IS 'Category of severe violation (if flagged)';
COMMENT ON COLUMN reports.manual_review_id IS 'Reference to manual review queue item';
