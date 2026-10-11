-- Synthetic identities only; no production account or record contents.
BEGIN;
INSERT INTO auth.users(id) SELECT ('00000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid FROM generate_series(1,5)n;
INSERT INTO public.profiles(id,full_name,role) VALUES
('00000000-0000-0000-0000-000000000001','Synthetic citizen one','citizen'),
('00000000-0000-0000-0000-000000000002','Synthetic citizen two','citizen'),
('00000000-0000-0000-0000-000000000003','Synthetic crew','field_crew'),
('00000000-0000-0000-0000-000000000004','Synthetic officer','officer'),
('00000000-0000-0000-0000-000000000005','Synthetic admin','admin');
INSERT INTO workflow_private.lifecycle_deployment(singleton,activated_at) VALUES(true,now());
INSERT INTO public.sweeper_configuration(parameter_name,parameter_value) VALUES('sla_threshold','{"hours":48}'),('maturation_threshold_hours','{"hours":24}'),('high_severity_maturation_hours','{"hours":12}');
INSERT INTO public.system_settings DEFAULT VALUES;
INSERT INTO public.notifications(user_id,title,body,type) VALUES('00000000-0000-0000-0000-000000000001','Synthetic notice','Synthetic body','general');
INSERT INTO storage.buckets(id,name,public) VALUES('Report Evidence','Report Evidence',true),('Cleanup Task Photos','Cleanup Task Photos',true),('Report Cleanup','Report Cleanup',true),('avatars','avatars',true);
INSERT INTO public.reports(user_id,title,issue_type,location,severity_score,validation_status)
VALUES('00000000-0000-0000-0000-000000000001','Synthetic initial report','waste',extensions.st_setsrid(extensions.st_makepoint(122,15),4326),2,'approved');
COMMIT;
