BEGIN;

-- 1. Create building_structures table for official city structures & address footprints
CREATE TABLE IF NOT EXISTS public.building_structures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  house_number text,
  street_name text,
  barangay text,
  building_name text,
  source text DEFAULT 'qgis_import',
  centroid_lat double precision,
  centroid_lng double precision,
  boundary extensions.geometry(Geometry, 4326) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 2. Spatial Index (GiST R-Tree) for rapid geographic proximity & containment searches
CREATE INDEX IF NOT EXISTS building_structures_geom_gist 
ON public.building_structures USING gist (boundary);

CREATE INDEX IF NOT EXISTS building_structures_street_idx 
ON public.building_structures (street_name);

CREATE INDEX IF NOT EXISTS building_structures_barangay_idx 
ON public.building_structures (barangay);

-- 3. Row Level Security & Grants
ALTER TABLE public.building_structures ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.building_structures FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.building_structures TO authenticated;
GRANT ALL ON TABLE public.building_structures TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ecopin_public_map_reader') THEN
    GRANT SELECT ON TABLE public.building_structures TO ecopin_public_map_reader;
  END IF;
END $$;

-- 4. Fast Spatial Matcher RPC: get_structure_address(lat, lng, buffer_meters)
-- Returns the closest building / house structure within buffer_meters (default 25.0 meters)
CREATE OR REPLACE FUNCTION public.get_structure_address(
  lat double precision, 
  lng double precision,
  buffer_meters double precision DEFAULT 25.0
)
RETURNS TABLE (
  house_number text,
  street_name text,
  building_name text,
  barangay text,
  distance_meters double precision
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions
AS $$
  SELECT 
    b.house_number,
    b.street_name,
    b.building_name,
    b.barangay,
    extensions.ST_Distance(
      b.boundary::extensions.geography,
      extensions.ST_SetSRID(extensions.ST_MakePoint(lng, lat), 4326)::extensions.geography
    ) AS distance_meters
  FROM public.building_structures b
  WHERE extensions.ST_DWithin(
    b.boundary::extensions.geography,
    extensions.ST_SetSRID(extensions.ST_MakePoint(lng, lat), 4326)::extensions.geography,
    buffer_meters
  )
  ORDER BY distance_meters ASC
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_structure_address(double precision, double precision, double precision) 
TO service_role, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ecopin_public_map_reader') THEN
    GRANT EXECUTE ON FUNCTION public.get_structure_address(double precision, double precision, double precision) TO ecopin_public_map_reader;
  END IF;
END $$;

COMMIT;
