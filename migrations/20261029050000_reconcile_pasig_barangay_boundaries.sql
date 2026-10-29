-- PDT-08: preserve polygon uncertainty; never assign by nearest centroid.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.pasig_barangay_roster(psgc_code text PRIMARY KEY,name text NOT NULL UNIQUE);
INSERT INTO public.pasig_barangay_roster VALUES
('1381200001','Bagong Ilog'),
('1381200002','Bagong Katipunan'),
('1381200003','Bambang'),
('1381200004','Buting'),
('1381200005','Caniogan'),
('1381200006','Dela Paz'),
('1381200007','Kalawaan'),
('1381200008','Kapasigan'),
('1381200009','Kapitolyo'),
('1381200010','Malinao'),
('1381200011','Manggahan'),
('1381200012','Maybunga'),
('1381200013','Oranbo'),
('1381200014','Palatiw'),
('1381200015','Pinagbuhatan'),
('1381200016','Pineda'),
('1381200017','Rosario'),
('1381200018','Sagad'),
('1381200019','San Antonio'),
('1381200020','San Joaquin'),
('1381200021','San Jose'),
('1381200022','San Miguel'),
('1381200023','San Nicolas'),
('1381200024','Santa Cruz'),
('1381200025','Santa Rosa'),
('1381200026','Santo Tomas'),
('1381200027','Santolan'),
('1381200028','Sumilang'),
('1381200029','Ugong'),
('1381200030','Santa Lucia');
ALTER TABLE public.pasig_barangay_roster ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pasig_barangay_roster FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.pasig_barangay_roster TO service_role;
CREATE TABLE public.pasig_barangay_boundary_source(
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),source_url text NOT NULL,source_sha256 text NOT NULL,imported_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pasig_barangay_boundary_source ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pasig_barangay_boundary_source FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT,INSERT,UPDATE ON public.pasig_barangay_boundary_source TO service_role;

CREATE FUNCTION public.resolve_report_barangay(lat double precision,lng double precision) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE p extensions.geometry; candidates text[]; interiors integer; covered integer; nearby integer; assigned text; code text; source_hash text;
BEGIN
 IF lat IS NULL OR lng IS NULL OR NOT(lat BETWEEN -90 AND 90) OR NOT(lng BETWEEN -180 AND 180) THEN
  RETURN jsonb_build_object('status','invalid_coordinates','barangay',NULL,'candidates','[]'::jsonb);
 END IF;
 -- Fail closed for missing, duplicate, invalid or unexpected administrative polygons.
 IF (SELECT count(*) FROM public.spatial_zones WHERE zone_type='barangay')<>30
   OR EXISTS(SELECT 1 FROM public.pasig_barangay_roster r WHERE
    (SELECT count(*) FROM public.spatial_zones z WHERE z.zone_type='barangay' AND z.zone_name=r.name AND z.boundary IS NOT NULL
     AND extensions.ST_SRID(z.boundary)=4326 AND NOT extensions.ST_IsEmpty(z.boundary)
     AND extensions.ST_IsValid(z.boundary) AND extensions.GeometryType(z.boundary) IN ('POLYGON','MULTIPOLYGON'))<>1) THEN
  RETURN jsonb_build_object('status','dataset_incomplete','barangay',NULL,'candidates','[]'::jsonb);
 END IF;
 p:=extensions.ST_SetSRID(extensions.ST_Point(lng,lat),4326);
 SELECT array_agg(zone_name ORDER BY zone_name),count(*) FILTER(WHERE inside),count(*) FILTER(WHERE covers),count(*) FILTER(WHERE near_edge)
 INTO candidates,interiors,covered,nearby FROM (
  SELECT z.zone_name,extensions.ST_Contains(z.boundary,p) AS inside,extensions.ST_Covers(z.boundary,p) AS covers,
   extensions.ST_DWithin(extensions.ST_Boundary(z.boundary)::extensions.geography,p::extensions.geography,25) AS near_edge
  FROM public.spatial_zones z WHERE z.zone_type='barangay' AND
   (extensions.ST_Covers(z.boundary,p) OR extensions.ST_DWithin(extensions.ST_Boundary(z.boundary)::extensions.geography,p::extensions.geography,25))
 ) matches;
 candidates:=coalesce(candidates,'{}'::text[]);
 SELECT source_sha256 INTO source_hash FROM public.pasig_barangay_boundary_source WHERE singleton;
 IF interiors>1 THEN
  RETURN jsonb_build_object('status','overlap','barangay',NULL,'candidates',candidates,'border_buffer_m',25,'source','spatial_zones','dataset_sha256',source_hash);
 ELSIF covered>1 OR nearby>0 THEN
  RETURN jsonb_build_object('status','border','barangay',NULL,'candidates',candidates,'border_buffer_m',25,'source','spatial_zones','dataset_sha256',source_hash);
 ELSIF interiors=1 AND covered=1 THEN
  assigned:=candidates[1];SELECT psgc_code INTO code FROM public.pasig_barangay_roster WHERE name=assigned;
  RETURN jsonb_build_object('status','resolved','barangay',assigned,'psgc_code',code,'candidates',candidates,'border_buffer_m',25,'source','spatial_zones','dataset_sha256',source_hash);
 END IF;
 RETURN jsonb_build_object('status','unresolved','barangay',NULL,'candidates',candidates,'border_buffer_m',25,'source','spatial_zones','dataset_sha256',source_hash);
END $$;

CREATE OR REPLACE FUNCTION public.get_report_barangay(lat double precision,lng double precision) RETURNS text
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT public.resolve_report_barangay(lat,lng)->>'barangay';
$$;

ALTER TABLE public.reports ADD COLUMN barangay_resolution_status text NOT NULL DEFAULT 'pending_reconciliation'
 CHECK(barangay_resolution_status IN ('pending_reconciliation','resolved','border','overlap','unresolved','dataset_incomplete','invalid_coordinates','unavailable')),
 ADD COLUMN barangay_candidates text[] NOT NULL DEFAULT '{}',ADD COLUMN barangay_resolution_checked_at timestamptz,
 ADD COLUMN location_district text;

CREATE FUNCTION workflow_private.resolve_report_barangay_fields() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 result:=public.resolve_report_barangay(extensions.ST_Y(NEW.location::extensions.geometry),extensions.ST_X(NEW.location::extensions.geometry));
 NEW.barangay:=result->>'barangay';NEW.barangay_resolution_status:=result->>'status';
 SELECT coalesce(array_agg(value),'{}'::text[]) INTO NEW.barangay_candidates FROM jsonb_array_elements_text(result->'candidates');
 NEW.barangay_resolution_checked_at:=statement_timestamp();RETURN NEW;
END $$;
CREATE TRIGGER b_resolve_report_barangay BEFORE INSERT OR UPDATE OF location,barangay,barangay_resolution_status,barangay_candidates,barangay_resolution_checked_at
 ON public.reports FOR EACH ROW EXECUTE FUNCTION workflow_private.resolve_report_barangay_fields();

-- One transactional import; no destructive DELETE or partial upload sequence.
CREATE FUNCTION public.import_pasig_barangay_boundaries(rows jsonb,source_url text,source_sha256 text) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE row jsonb; g extensions.geometry; geoms extensions.geometry[]:='{}'; raw_geoms jsonb[]:='{}'; names text[]:='{}'; ids text[]:='{}'; expected_name text; i integer; j integer; anchor extensions.geometry;
BEGIN
 IF jsonb_typeof(rows) IS DISTINCT FROM 'array' OR jsonb_array_length(rows)<>30
  OR source_url IS NULL OR source_url !~ '^https://' OR source_sha256 IS NULL OR source_sha256 !~ '^[a-f0-9]{64}$' THEN
  RAISE EXCEPTION 'A complete 30-polygon source with HTTPS provenance and SHA-256 is required.' USING ERRCODE='22023';
 END IF;
 FOR row IN SELECT value FROM jsonb_array_elements(rows) LOOP
  SELECT name INTO expected_name FROM public.pasig_barangay_roster WHERE psgc_code=row->>'psgc_code';
  IF expected_name IS NULL OR expected_name IS DISTINCT FROM row->>'name' OR expected_name=ANY(names) THEN
   RAISE EXCEPTION 'Missing, duplicate or mismatched Pasig PSGC/name.' USING ERRCODE='22023';
  END IF;
  g:=extensions.ST_GeomFromGeoJSON(row->'geometry');
  IF g IS NULL OR extensions.ST_SRID(g)<>4326 OR extensions.ST_IsEmpty(g) OR NOT extensions.ST_IsValid(g)
   OR extensions.GeometryType(g) NOT IN ('POLYGON','MULTIPOLYGON') THEN RAISE EXCEPTION 'Invalid WGS84 polygon: %',expected_name USING ERRCODE='22023'; END IF;
  IF NOT extensions.ST_CoveredBy(g,extensions.ST_MakeEnvelope(121.0,14.49,121.17,14.66,4326)) THEN
   RAISE EXCEPTION 'Polygon lies outside the Pasig validation envelope: %',expected_name USING ERRCODE='22023';
  END IF;
  geoms:=array_append(geoms,g);raw_geoms:=array_append(raw_geoms,row->'geometry');names:=array_append(names,expected_name);ids:=array_append(ids,'barangay_'||regexp_replace(lower(expected_name),'[^a-z0-9]+','_','g'));
 END LOOP;
 FOR i IN 1..30 LOOP
  FOR j IN (i+1)..30 LOOP
   IF extensions.ST_Area(extensions.ST_Intersection(geoms[i],geoms[j]))>0 THEN RAISE EXCEPTION 'Overlapping polygons: % / %',names[i],names[j] USING ERRCODE='22023'; END IF;
  END LOOP;
 END LOOP;
 LOCK TABLE public.spatial_zones IN SHARE ROW EXCLUSIVE MODE;
 IF EXISTS(SELECT 1 FROM public.spatial_zones WHERE zone_type='barangay' AND NOT(id=ANY(ids)))
  OR EXISTS(SELECT 1 FROM public.spatial_zones WHERE id=ANY(ids) AND zone_type<>'barangay') THEN
  RAISE EXCEPTION 'Existing zone IDs need manual reconciliation; no data was removed.' USING ERRCODE='23505';
 END IF;
 FOR i IN 1..30 LOOP
  anchor:=extensions.ST_PointOnSurface(geoms[i]);
  INSERT INTO public.spatial_zones(id,zone_name,zone_type,boundary_geojson,centroid_lat,centroid_lng)
   VALUES(ids[i],names[i],'barangay',raw_geoms[i],extensions.ST_Y(anchor),extensions.ST_X(anchor))
  ON CONFLICT(id) DO UPDATE SET zone_name=excluded.zone_name,boundary_geojson=excluded.boundary_geojson,centroid_lat=excluded.centroid_lat,centroid_lng=excluded.centroid_lng;
 END LOOP;
 INSERT INTO public.pasig_barangay_boundary_source(singleton,source_url,source_sha256) VALUES(true,source_url,source_sha256)
 ON CONFLICT(singleton) DO UPDATE SET source_url=excluded.source_url,source_sha256=excluded.source_sha256,imported_at=clock_timestamp();
 RETURN jsonb_build_object('imported',30,'source_sha256',source_sha256,'report_reconciliation_required',true);
END $$;

REVOKE ALL ON FUNCTION public.resolve_report_barangay(double precision,double precision),public.get_report_barangay(double precision,double precision),
 workflow_private.resolve_report_barangay_fields(),public.import_pasig_barangay_boundaries(jsonb,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_report_barangay(double precision,double precision),public.get_report_barangay(double precision,double precision),
 public.import_pasig_barangay_boundaries(jsonb,text,text) TO service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
