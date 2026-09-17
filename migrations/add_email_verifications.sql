-- Create email_verifications table
CREATE TABLE IF NOT EXISTS public.email_verifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    token UUID NOT NULL DEFAULT gen_random_uuid(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    used_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Add index on token for fast lookups
CREATE INDEX IF NOT EXISTS idx_email_verifications_token ON public.email_verifications(token);

-- Add index on user_id
CREATE INDEX IF NOT EXISTS idx_email_verifications_user_id ON public.email_verifications(user_id);

-- Add is_email_verified to profiles table
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_email_verified BOOLEAN DEFAULT true;

-- Note: We default is_email_verified to true so that existing users (who presumably
-- already verified via Supabase's built-in flow or were manually created) 
-- don't get locked out. New registrations will have this explicitly set to false
-- during the registration process in the backend controller.
