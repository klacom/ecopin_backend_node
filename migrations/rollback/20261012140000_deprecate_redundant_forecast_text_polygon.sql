-- =============================================================================
-- Rollback Migration: 20261012140000_deprecate_redundant_forecast_text_polygon.sql
-- Description: Re-adds legacy region_polygon text column to hotspot_predictions.
-- =============================================================================

BEGIN;

-- 1. Restore redundant text column
ALTER TABLE public.hotspot_predictions
  ADD COLUMN IF NOT EXISTS region_polygon text;

-- 2. Populate from canonical geojson_polygon if available
UPDATE public.hotspot_predictions
SET region_polygon = geojson_polygon::text
WHERE region_polygon IS NULL AND geojson_polygon IS NOT NULL;

-- 3. Restore column documentation
COMMENT ON COLUMN public.hotspot_predictions.region_polygon IS
  'Legacy GeoJSON polygon for irregular hotspot regions restored via rollback.';

COMMIT;
