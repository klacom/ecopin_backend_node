-- Create audit_logs table for system-wide events
-- This table tracks system events like logins, password changes, role changes, etc.

CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    action_type VARCHAR(50) NOT NULL,
    action_details TEXT,
    ip_address VARCHAR(45),
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now())
);

-- Create index on user_id for faster queries
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_action_type ON audit_logs(action_type);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at DESC);

-- Add RLS policies
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- Only allow admins to read audit logs
CREATE POLICY "Allow admins to read audit logs"
    ON audit_logs FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    );

-- Only allow system to insert audit logs (via service role)
CREATE POLICY "Allow service role to insert audit logs"
    ON audit_logs FOR INSERT
    TO service_role
    WITH CHECK (true);

-- Create a function to update updated_at timestamp (for consistency with other tables)
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = timezone('utc'::text, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Comment on the table
COMMENT ON TABLE audit_logs IS 'System-wide audit log for tracking user actions like logins, password changes, role changes, etc.';

COMMENT ON COLUMN audit_logs.action_type IS 'Type of action performed (e.g., login, logout, password_change, role_change)';
COMMENT ON COLUMN audit_logs.action_details IS 'Additional details about the action';
COMMENT ON COLUMN audit_logs.ip_address IS 'IP address from which the action was performed';
COMMENT ON COLUMN audit_logs.user_agent IS 'User agent string of the client';
