-- Migration: Update hotspot forecasting to report-based approach
-- Description: Remove cluster dependency, add region geometry for hotspot polygons

-- Drop existing hotspot_predictions table and recreate with report-based schema
DROP TABLE IF EXISTS hotspot_predictions CASCADE;

-- Create new hotspot_predictions table for report-based hotspots
CREATE TABLE hotspot_predictions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    region_id VARCHAR(255) NOT NULL, -- Unique identifier for the hotspot region
    time_horizon VARCHAR(50) NOT NULL, -- 'daily', 'weekly', 'monthly'
    prediction_date DATE NOT NULL,
    
    -- Risk metrics
    risk_score DECIMAL(5,4) NOT NULL, -- 0.0 to 1.0
    report_count INTEGER NOT NULL,
    gi_statistic DECIMAL(10,6),
    p_value DECIMAL(10,8),
    is_significant BOOLEAN DEFAULT FALSE,
    risk_level VARCHAR(20) NOT NULL, -- 'high', 'medium', 'low'
    
    -- Region geometry
    region_center_lat DECIMAL(10,8) NOT NULL,
    region_center_lng DECIMAL(11,8) NOT NULL,
    region_radius_meters DECIMAL(10,2), -- For circular hotspots
    region_polygon TEXT, -- GeoJSON polygon for irregular hotspots
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for efficient queries
CREATE INDEX idx_hotspot_predictions_time_horizon ON hotspot_predictions(time_horizon);
CREATE INDEX idx_hotspot_predictions_date ON hotspot_predictions(prediction_date);
CREATE INDEX idx_hotspot_predictions_risk_score ON hotspot_predictions(risk_score DESC);
CREATE INDEX idx_hotspot_predictions_region_id ON hotspot_predictions(region_id);
CREATE INDEX idx_hotspot_predictions_composite ON hotspot_predictions(time_horizon, prediction_date);

-- Add unique constraint to prevent duplicate predictions for same region/date/horizon
CREATE UNIQUE INDEX idx_hotspot_predictions_unique 
ON hotspot_predictions(region_id, prediction_date, time_horizon);

-- Add comments for documentation
COMMENT ON TABLE hotspot_predictions IS 'Stores hotspot predictions based on report analysis, not cluster-based';
COMMENT ON COLUMN hotspot_predictions.region_id IS 'Unique identifier for the hotspot region (e.g., grid cell ID)';
COMMENT ON COLUMN hotspot_predictions.region_center_lat IS 'Latitude of hotspot region center';
COMMENT ON COLUMN hotspot_predictions.region_center_lng IS 'Longitude of hotspot region center';
COMMENT ON COLUMN hotspot_predictions.region_radius_meters IS 'Radius in meters for circular hotspots';
COMMENT ON COLUMN hotspot_predictions.region_polygon IS 'GeoJSON polygon for irregular hotspot regions';

-- Keep hotspot_accuracy table but update comments
COMMENT ON TABLE hotspot_accuracy IS 'Stores accuracy metrics for hotspot predictions (report-based)';
