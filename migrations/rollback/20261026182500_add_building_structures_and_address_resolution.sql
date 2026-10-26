BEGIN;

DROP FUNCTION IF EXISTS public.get_structure_address(double precision, double precision, double precision);
DROP TABLE IF EXISTS public.building_structures;

COMMIT;
