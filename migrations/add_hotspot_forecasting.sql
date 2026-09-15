-- Hotspot Forecasting Database Schema
-- Creates tables for storing predictions and tracking accuracy

-- Hotspot predictions storage
CREATE TABLE IF NOT EXISTS hotspot_predictions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id UUID REFERENCES clusters(id) ON DELETE SET NULL,
    time_horizon VARCHAR(20) NOT NULL CHECK (time_horizon IN ('daily', 'weekly', 'monthly')),
    prediction_date DATE NOT NULL,
    risk_score DECIMAL(5,4) NOT NULL CHECK (risk_score >= 0 AND risk_score <= 1),
    report_count INTEGER NOT NULL DEFAULT 0,
    gi_statistic DECIMAL(10,4),
    p_value DECIMAL(10,6),
    is_significant BOOLEAN DEFAULT FALSE,
    risk_level VARCHAR(10) CHECK (risk_level IN ('low', 'medium', 'high')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Historical accuracy tracking
CREATE TABLE IF NOT EXISTS hotspot_accuracy (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    prediction_id UUID REFERENCES hotspot_predictions(id) ON DELETE CASCADE,
    actual_reports INTEGER NOT NULL,
    predicted_reports INTEGER NOT NULL,
    accuracy_score DECIMAL(5,4) CHECK (accuracy_score >= 0 AND accuracy_score <= 1),
    time_horizon VARCHAR(20) NOT NULL CHECK (time_horizon IN ('daily', 'weekly', 'monthly')),
    evaluation_date DATE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_hotspot_predictions_date ON hotspot_predictions(prediction_date);
CREATE INDEX IF NOT EXISTS idx_hotspot_predictions_horizon ON hotspot_predictions(time_horizon);
CREATE INDEX IF NOT EXISTS idx_hotspot_predictions_cluster ON hotspot_predictions(cluster_id);
CREATE INDEX IF NOT EXISTS idx_hotspot_predictions_risk ON hotspot_predictions(risk_score);
CREATE INDEX IF NOT EXISTS idx_hotspot_predictions_significant ON hotspot_predictions(is_significant) WHERE is_significant = TRUE;

CREATE INDEX IF NOT EXISTS idx_hotspot_accuracy_prediction ON hotspot_accuracy(prediction_id);
CREATE INDEX IF NOT EXISTS idx_hotspot_accuracy_horizon ON hotspot_accuracy(time_horizon);
CREATE INDEX IF NOT EXISTS idx_hotspot_accuracy_date ON hotspot_accuracy(evaluation_date);

-- Add comments for documentation
COMMENT ON TABLE hotspot_predictions IS 'Stores hotspot forecasting predictions with risk scores and statistical significance';
COMMENT ON TABLE hotspot_accuracy IS 'Tracks prediction accuracy by comparing predicted vs actual report counts';

COMMENT ON COLUMN hotspot_predictions.risk_score IS 'Normalized risk score from 0 to 1, higher values indicate higher hotspot probability';
COMMENT ON COLUMN hotspot_predictions.gi_statistic IS 'Getis-Ord Gi* statistic value for spatial clustering significance';
COMMENT ON COLUMN hotspot_predictions.p_value IS 'Statistical significance p-value, values < 0.05 indicate significant hotspots';
COMMENT ON COLUMN hotspot_predictions.is_significant IS 'True if p_value < 0.05 and |gi_statistic| > 1.96 (95% confidence)';

COMMENT ON COLUMN hotspot_accuracy.accuracy_score IS 'Calculated as 1 - |actual - predicted| / max(actual, predicted)';
