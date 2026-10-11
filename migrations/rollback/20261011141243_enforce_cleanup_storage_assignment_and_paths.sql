ALTER POLICY "Authenticated users can upload Cleanup Task Photos" ON storage.objects WITH CHECK (((bucket_id = 'Cleanup Task Photos'::text) AND ((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['field_crew'::text, 'officer'::text, 'admin'::text]))));
ALTER POLICY "Authenticated users can upload Report Cleanup" ON storage.objects WITH CHECK (((bucket_id = 'Report Cleanup'::text) AND ((( SELECT get_auth_user_role() AS get_auth_user_role))::text = ANY (ARRAY['field_crew'::text, 'officer'::text, 'admin'::text]))));
DROP FUNCTION storage_authority.can_upload_cleanup_object(text,text);
DROP SCHEMA storage_authority;
