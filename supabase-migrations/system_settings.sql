-- Create system_settings table for website configuration
-- This table stores global settings like password requirements, session timeout, etc.

CREATE TABLE IF NOT EXISTS system_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    password_min_length INTEGER DEFAULT 8,
    password_require_uppercase BOOLEAN DEFAULT true,
    password_require_lowercase BOOLEAN DEFAULT true,
    password_require_numbers BOOLEAN DEFAULT true,
    password_require_special_chars BOOLEAN DEFAULT true,
    session_timeout_minutes INTEGER DEFAULT 60,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now())
);

-- Insert default settings
INSERT INTO system_settings (
    password_min_length,
    password_require_uppercase,
    password_require_lowercase,
    password_require_numbers,
    password_require_special_chars,
    session_timeout_minutes
) VALUES (
    8,
    true,
    true,
    true,
    true,
    60
) ON CONFLICT DO NOTHING;

-- Create a function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = timezone('utc'::text, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create a trigger to automatically update updated_at
CREATE TRIGGER update_system_settings_updated_at
    BEFORE UPDATE ON system_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Add RLS policies (if needed)
ALTER TABLE system_settings ENABLE ROW LEVEL SECURITY;

-- Only allow authenticated users to read settings
CREATE POLICY "Allow authenticated to read settings"
    ON system_settings FOR SELECT
    TO authenticated
    USING (true);

-- Only allow admins to update settings
CREATE POLICY "Allow admins to update settings"
    ON system_settings FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    );

-- Only allow admins to insert settings
CREATE POLICY "Allow admins to insert settings"
    ON system_settings FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    );
