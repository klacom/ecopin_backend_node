-- Rollback: 20261012130000_harden_storage_delivery_and_delete_matrix.sql
-- Description: Restores previous storage policies and public bucket configuration.

SET LOCAL lock_timeout = '2s';

UPDATE storage.buckets SET public = true WHERE id IN ('Report Evidence', 'Cleanup Task Photos', 'Report Cleanup');

DROP POLICY IF EXISTS "Users and officers can delete Report Evidence" ON storage.objects;
DROP POLICY IF EXISTS "Authorized users can delete Report Cleanup" ON storage.objects;
DROP POLICY IF EXISTS "Authorized users can delete Cleanup Task Photos" ON storage.objects;

DROP POLICY IF EXISTS "Authorized users can view Report Cleanup" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can view Report Cleanup" ON storage.objects;
CREATE POLICY "Public can view Report Cleanup" ON storage.objects
FOR SELECT TO public
USING (bucket_id = 'Report Cleanup');

DROP POLICY IF EXISTS "Authorized users can view Cleanup Task Photos" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can view Cleanup Task Photos" ON storage.objects;
CREATE POLICY "Public can view Cleanup Task Photos" ON storage.objects
FOR SELECT TO public
USING (bucket_id = 'Cleanup Task Photos');

DROP POLICY IF EXISTS "Authorized users can view Report Evidence" ON storage.objects;
CREATE POLICY "Public can view Report Evidence" ON storage.objects
FOR SELECT TO public
USING (bucket_id = 'Report Evidence');

CREATE POLICY "public_read 1oj01fe_0" ON storage.objects
FOR SELECT TO public
USING (bucket_id = 'avatars');

DROP FUNCTION IF EXISTS storage_authority.can_read_cleanup_object(text, text);
