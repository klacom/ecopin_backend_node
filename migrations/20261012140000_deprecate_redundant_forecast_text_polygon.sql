-- =============================================================================
-- Migration: 20261012140000_deprecate_redundant_forecast_text_polygon.sql
-- Description: Deprecate and drop legacy redundant text polygon column
--              from hotspot_predictions in favor of canonical geojson_polygon (jsonb).
-- Safety: Pre-migration verified that all existing rows have region_polygon = NULL
--         and geojson_polygon populated. No active application callers reference
--         region_polygon across backend, web dashboard, or mobile app.
-- =============================================================================

BEGIN;

-- 1. Ensure any legacy text data is preserved in geojson_polygon if not already populated
UPDATE public.hotspot_predictions
SET geojson_polygon = region_polygon::jsonb
WHERE region_polygon IS NOT NULL AND geojson_polygon IS NULL;

-- 2. Drop the redundant text column
ALTER TABLE public.hotspot_predictions
  DROP COLUMN IF EXISTS region_polygon;

-- 3. Document canonical geometry standard on the table
COMMENT ON TABLE public.hotspot_predictions IS
  'Spatial hotspot forecasts utilizing canonical geojson_polygon (jsonb) geometry. Legacy region_polygon text column removed via migration 20261012140000.';

COMMIT;
