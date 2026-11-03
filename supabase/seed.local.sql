-- Synthetic local identities and committed reference data only. Never run on a hosted database.
BEGIN;
INSERT INTO public.profiles(id,full_name,role,data_consent,is_email_verified)
SELECT id,'Synthetic '||split_part(email,'@',1),(raw_app_meta_data->>'role')::public.role,true,true
FROM auth.users WHERE raw_app_meta_data->>'fixture'='ecopin-parity-local' AND email LIKE '%@parity.ecopin.invalid'
ON CONFLICT(id) DO UPDATE SET full_name=excluded.full_name,role=excluded.role,data_consent=true,is_email_verified=true;
DO $$ BEGIN IF (SELECT count(*) FROM public.profiles p JOIN auth.users u USING(id)
 WHERE u.raw_app_meta_data->>'fixture'='ecopin-parity-local')<>5 THEN RAISE EXCEPTION 'Seed the five local Auth fixtures first'; END IF; END $$;

-- Same PSA roster already committed in data/pasig-barangay-roster.json and the reviewed migration.
INSERT INTO public.pasig_barangay_roster(psgc_code,name) VALUES
('1381200001','Bagong Ilog'),('1381200002','Bagong Katipunan'),('1381200003','Bambang'),
('1381200004','Buting'),('1381200005','Caniogan'),('1381200006','Dela Paz'),
('1381200007','Kalawaan'),('1381200008','Kapasigan'),('1381200009','Kapitolyo'),
('1381200010','Malinao'),('1381200011','Manggahan'),('1381200012','Maybunga'),
('1381200013','Oranbo'),('1381200014','Palatiw'),('1381200015','Pinagbuhatan'),
('1381200016','Pineda'),('1381200017','Rosario'),('1381200018','Sagad'),
('1381200019','San Antonio'),('1381200020','San Joaquin'),('1381200021','San Jose'),
('1381200022','San Miguel'),('1381200023','San Nicolas'),('1381200024','Santa Cruz'),
('1381200025','Santa Rosa'),('1381200026','Santo Tomas'),('1381200027','Santolan'),
('1381200028','Sumilang'),('1381200029','Ugong'),('1381200030','Santa Lucia')
ON CONFLICT(psgc_code) DO NOTHING;

INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES
('Cleanup Originals','Cleanup Originals',false,10485760,ARRAY['image/jpeg','image/png','image/webp']),
('Cleanup Proof','Cleanup Proof',false,10485760,ARRAY['image/jpeg']),
('Report Evidence','Report Evidence',false,10485760,ARRAY['image/jpg','image/jpeg','image/png']),
('Report Cleanup','Report Cleanup',false,10485760,ARRAY['image/jpeg','image/png','image/webp','image/jpg']),
('Cleanup Task Photos','Cleanup Task Photos',false,10485760,ARRAY['image/jpeg','image/png','image/webp','image/jpg'])
ON CONFLICT(id) DO NOTHING;

INSERT INTO workflow_private.unprocessed_escalation_baseline(singleton,cutoff)
VALUES(true,date_trunc('month',statement_timestamp())-interval '2 months') ON CONFLICT(singleton) DO NOTHING;
COMMIT;
