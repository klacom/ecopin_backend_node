DROP FUNCTION public.read_authorized_report_detail(uuid,uuid);
SET LOCAL lock_timeout='2s';
DROP VIEW public.public_reports;
DROP POLICY public_map_reader_approved_consent ON public.reports;
REVOKE ALL ON public.reports FROM ecopin_public_map_reader;
REVOKE SELECT (id,title,description,issue_type,status,cluster_id,created_at,updated_at,stage,is_overdue,severity_score,severity_level,lifecycle_state,breached_at,validation_status,location,on_private_property,property_owner_consent_status) ON public.reports FROM ecopin_public_map_reader;
REVOKE ALL ON SCHEMA public,extensions FROM ecopin_public_map_reader;
REVOKE ecopin_public_map_reader FROM postgres;
DROP ROLE ecopin_public_map_reader;
