-- Create strikes table for tracking user violations
-- This table tracks strikes issued to users for policy violations

CREATE TABLE IF NOT EXISTS strikes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
    reason TEXT NOT NULL,
    violation_type VARCHAR(50) NOT NULL, -- e.g., 'spam', 'harassment', 'inappropriate_content'
    issued_by UUID REFERENCES profiles(id), -- Admin who issued the strike
    issued_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()),
    expires_at TIMESTAMP WITH TIME ZONE, -- When the strike expires (null for permanent strikes)
    is_active BOOLEAN DEFAULT true,
    notes TEXT
);

-- Create indexes for faster queries
CREATE INDEX IF NOT EXISTS idx_strikes_user_id ON strikes(user_id);
CREATE INDEX IF NOT EXISTS idx_strikes_issued_by ON strikes(issued_by);
CREATE INDEX IF NOT EXISTS idx_strikes_is_active ON strikes(is_active);
CREATE INDEX IF NOT EXISTS idx_strikes_expires_at ON strikes(expires_at);

-- Add RLS policies
ALTER TABLE strikes ENABLE ROW LEVEL SECURITY;

-- Allow users to view their own strikes
CREATE POLICY "Allow users to view own strikes"
    ON strikes FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

-- Allow admins to view all strikes
CREATE POLICY "Allow admins to view all strikes"
    ON strikes FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role IN ('admin', 'lgu')
        )
    );

-- Only allow admins to insert strikes
CREATE POLICY "Allow admins to insert strikes"
    ON strikes FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role IN ('admin', 'lgu')
        )
    );

-- Only allow admins to update strikes
CREATE POLICY "Allow admins to update strikes"
    ON strikes FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role IN ('admin', 'lgu')
        )
    );

-- Only allow admins to delete strikes
CREATE POLICY "Allow admins to delete strikes"
    ON strikes FOR DELETE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role IN ('admin', 'lgu')
        )
    );

-- Add comments
COMMENT ON TABLE strikes IS 'Tracks strikes issued to users for policy violations';
COMMENT ON COLUMN strikes.reason IS 'Detailed reason for the strike';
COMMENT ON COLUMN strikes.violation_type IS 'Type of violation (e.g., spam, harassment, inappropriate_content)';
COMMENT ON COLUMN strikes.issued_by IS 'ID of the admin who issued the strike';
COMMENT ON COLUMN strikes.issued_at IS 'Timestamp when the strike was issued';
COMMENT ON COLUMN strikes.expires_at IS 'When the strike expires (null for permanent strikes)';
COMMENT ON COLUMN strikes.is_active IS 'Whether the strike is currently active';
COMMENT ON COLUMN strikes.notes IS 'Additional notes about the strike';

-- Add suspension tracking to profiles table
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS suspended_until TIMESTAMP WITH TIME ZONE;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS strike_count INTEGER DEFAULT 0;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS last_strike_at TIMESTAMP WITH TIME ZONE;

-- Create index on suspended_until for faster queries
CREATE INDEX IF NOT EXISTS idx_profiles_suspended_until ON profiles(suspended_until);

-- Add comments to new profile columns
COMMENT ON COLUMN profiles.suspended_until IS 'Timestamp until which the user is suspended (null if not suspended)';
COMMENT ON COLUMN profiles.strike_count IS 'Current number of active strikes';
COMMENT ON COLUMN profiles.last_strike_at IS 'Timestamp of the most recent strike';

-- Update system_settings to include strike configuration
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS strike_1_action VARCHAR(50) DEFAULT 'warning';
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS strike_2_action VARCHAR(50) DEFAULT 'suspend_24h';
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS strike_3_action VARCHAR(50) DEFAULT 'suspend_7d';
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS strike_4_action VARCHAR(50) DEFAULT 'permanent_ban';
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS strike_2_duration_hours INTEGER DEFAULT 24;
ALTER TABLE system_settings ADD COLUMN IF NOT EXISTS strike_3_duration_hours INTEGER DEFAULT 168; -- 7 days = 168 hours

-- Add comments to new system_settings columns
COMMENT ON COLUMN system_settings.strike_1_action IS 'Action for first strike (warning, suspend_24h, suspend_7d, permanent_ban)';
COMMENT ON COLUMN system_settings.strike_2_action IS 'Action for second strike (warning, suspend_24h, suspend_7d, permanent_ban)';
COMMENT ON COLUMN system_settings.strike_3_action IS 'Action for third strike (warning, suspend_24h, suspend_7d, permanent_ban)';
COMMENT ON COLUMN system_settings.strike_4_action IS 'Action for fourth and subsequent strikes (warning, suspend_24h, suspend_7d, permanent_ban)';
COMMENT ON COLUMN system_settings.strike_2_duration_hours IS 'Duration in hours for 24h suspension action';
COMMENT ON COLUMN system_settings.strike_3_duration_hours IS 'Duration in hours for 7d suspension action';

-- Update default settings with strike configuration
UPDATE system_settings SET
    strike_1_action = 'warning',
    strike_2_action = 'suspend_24h',
    strike_3_action = 'suspend_7d',
    strike_4_action = 'permanent_ban',
    strike_2_duration_hours = 24,
    strike_3_duration_hours = 168
WHERE id IS NOT NULL;
