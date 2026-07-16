-- Create notifications table for user notifications
-- This table stores notifications for users about their reports and account status

CREATE TABLE IF NOT EXISTS notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
    report_id UUID REFERENCES reports(id) ON DELETE CASCADE,
    type VARCHAR(50) NOT NULL, -- 'pending_validation', 'approved', 'rejected', 'suspended', 'resolved', 'lifecycle_update', etc.
    title VARCHAR(255) NOT NULL,
    body TEXT,
    is_read BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now())
);

-- Create indexes for faster queries
CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_is_read ON notifications(is_read);
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON notifications(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_type ON notifications(type);

-- Add RLS policies
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- Allow users to view their own notifications
CREATE POLICY "Allow users to view own notifications"
    ON notifications FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

-- Allow users to mark their own notifications as read
CREATE POLICY "Allow users to update own notifications"
    ON notifications FOR UPDATE
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- Only allow system to insert notifications (via service role)
CREATE POLICY "Allow service role to insert notifications"
    ON notifications FOR INSERT
    TO service_role
    WITH CHECK (true);

-- Add comments
COMMENT ON TABLE notifications IS 'User notifications about reports and account status';
COMMENT ON COLUMN notifications.type IS 'Type of notification (pending_validation, approved, rejected, suspended, resolved, lifecycle_update, etc.)';
COMMENT ON COLUMN notifications.is_read IS 'Whether the notification has been read by the user';
