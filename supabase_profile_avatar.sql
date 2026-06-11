-- 1. Update profiles table to add avatar_url column
ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- 2. Create storage bucket for avatars
-- Note: This must be executed in Supabase Dashboard's SQL Editor or using Supabase CLI
-- because it uses storage.create_bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('avatars', 'avatars', true, 5242880, '{image/jpeg,image/png,image/webp}')
ON CONFLICT (id) DO NOTHING;

-- 3. Enable RLS on the avatars bucket
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- 4. Create policies for avatars bucket
-- Policy: Users can view all avatars
CREATE POLICY IF NOT EXISTS "Public can view avatars"
ON storage.objects FOR SELECT
USING (bucket_id = 'avatars');

-- Policy: Users can upload their own avatars
CREATE POLICY IF NOT EXISTS "Users can upload their own avatars"
ON storage.objects FOR INSERT
WITH CHECK (
    bucket_id = 'avatars' AND
    (auth.uid()::text || '/') = (storage.foldername(name) || '/')
);

-- Policy: Users can update their own avatars
CREATE POLICY IF NOT EXISTS "Users can update their own avatars"
ON storage.objects FOR UPDATE
USING (
    bucket_id = 'avatars' AND
    (auth.uid()::text || '/') = (storage.foldername(name) || '/')
);

-- Policy: Users can delete their own avatars
CREATE POLICY IF NOT EXISTS "Users can delete their own avatars"
ON storage.objects FOR DELETE
USING (
    bucket_id = 'avatars' AND
    (auth.uid()::text || '/') = (storage.foldername(name) || '/')
);

-- 5. Update RLS for profiles table to allow users to update their own profile
-- If you don't already have these policies:
CREATE POLICY IF NOT EXISTS "Users can view their own profile"
ON public.profiles FOR SELECT
USING (auth.uid() = id);

CREATE POLICY IF NOT EXISTS "Users can update their own profile"
ON public.profiles FOR UPDATE
USING (auth.uid() = id);