-- Export new forecasts before rollback: new forecast columns and zone catalog are removed.
-- Existing reports and all prediction rows are retained. Service-only forecast access stays.
BEGIN;
SET LOCAL lock_timeout = '5s';
DROP VIEW public.zone_weekly_report_history;
DROP INDEX public.hotspot_predictions_zone_horizon_date;
ALTER TABLE public.hotspot_predictions
  DROP COLUMN zone_id,
  DROP COLUMN zone_name,
  DROP COLUMN horizon_days,
  DROP COLUMN forecast_date_start,
  DROP COLUMN forecast_date_end,
  DROP COLUMN predicted_count,
  DROP COLUMN predicted_lower_bound,
  DROP COLUMN predicted_upper_bound,
  DROP COLUMN growth_velocity_percent,
  DROP COLUMN historical_points,
  DROP COLUMN forecast_points,
  DROP COLUMN model_version;
DROP TABLE public.spatial_zones;
COMMIT;
