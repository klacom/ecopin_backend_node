// Spatial Forecast Client Service
// Handles communication with Python hotspot forecasting service

import { supabaseAdmin } from '../../../config/supabase.config.js';
import { SPATIAL_FORECAST_CONFIG } from '../config/spatial.config.js';

/**
 * Generate hotspot forecast by calling Python service
 */
export const generateForecast = async (timeHorizon = 'weekly', boundingBox = null) => {
  try {
    console.log(`[SpatialForecast] Generating forecast for ${timeHorizon} horizon`);
    
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), SPATIAL_FORECAST_CONFIG.timeout);
    
    const requestBody = {
      time_horizon: timeHorizon
    };
    
    if (boundingBox) {
      requestBody.bounding_box = boundingBox;
    }
    
    const response = await fetch(`${SPATIAL_FORECAST_CONFIG.serviceUrl}/forecast`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(requestBody),
      signal: controller.signal,
    });
    
    clearTimeout(timeout);
    
    if (!response.ok) {
      const errorText = await response.text().catch(() => '');
      throw new Error(`Spatial forecast service returned HTTP ${response.status}: ${errorText}`);
    }
    
    const result = await response.json();
    
    // Store predictions in database
    await storePredictions(result);
    
    console.log(`[SpatialForecast] Forecast generated and stored: ${result.hotspot_count} hotspots`);
    return result;
    
  } catch (error) {
    console.error('[SpatialForecast] Error generating forecast:', error);
    throw error;
  }
};

/**
 * Store predictions in database
 */
const storePredictions = async (forecastResult) => {
  try {
    const { region_analyses, time_horizon, prediction_date } = forecastResult;
    
    const predictionsToInsert = [];
    
    for (const [regionId, analysis] of Object.entries(region_analyses)) {
      predictionsToInsert.push({
        region_id: regionId,
        time_horizon: time_horizon,
        prediction_date: prediction_date.split('T')[0],
        risk_score: analysis.risk_score,
        report_count: analysis.report_count,
        gi_statistic: analysis.gi_star,
        p_value: analysis.p_value,
        is_significant: analysis.is_significant,
        risk_level: analysis.risk_level,
        region_center_lat: analysis.region_center_lat,
        region_center_lng: analysis.region_center_lng,
        region_radius_meters: analysis.region_radius_meters
      });
    }
    
    if (predictionsToInsert.length > 0) {
      const { error } = await supabaseAdmin
        .from('hotspot_predictions')
        .upsert(predictionsToInsert, { onConflict: 'region_id,prediction_date,time_horizon' });
      
      if (error) {
        console.error('[SpatialForecast] Error storing predictions:', error);
        throw error;
      }
      
      console.log(`[SpatialForecast] Stored ${predictionsToInsert.length} predictions`);
    }
    
  } catch (error) {
    console.error('[SpatialForecast] Error storing predictions:', error);
    throw error;
  }
};

/**
 * Fetch historical predictions from database
 */
export const getPredictions = async (filters = {}) => {
  try {
    let query = supabaseAdmin
      .from('hotspot_predictions')
      .select('*')
      .order('prediction_date', { ascending: false });
    
    // Apply filters
    if (filters.timeHorizon) {
      query = query.eq('time_horizon', filters.timeHorizon);
    }
    
    if (filters.regionId) {
      query = query.eq('region_id', filters.regionId);
    }
    
    if (filters.startDate) {
      query = query.gte('prediction_date', filters.startDate);
    }
    
    if (filters.endDate) {
      query = query.lte('prediction_date', filters.endDate);
    }
    
    if (filters.isSignificant !== undefined) {
      query = query.eq('is_significant', filters.isSignificant);
    }
    
    if (filters.limit) {
      query = query.limit(filters.limit);
    }
    
    const { data, error } = await query;
    
    if (error) throw error;
    
    return data;
    
  } catch (error) {
    console.error('[SpatialForecast] Error fetching predictions:', error);
    throw error;
  }
};

/**
 * Get current predictions for a specific time horizon
 */
export const getCurrentPredictions = async (timeHorizon = 'weekly') => {
  try {
    const today = new Date().toISOString().split('T')[0];
    
    const { data, error } = await supabaseAdmin
      .from('hotspot_predictions')
      .select('*')
      .eq('time_horizon', timeHorizon)
      .eq('prediction_date', today)
      .order('risk_score', { ascending: false });
    
    if (error) throw error;
    
    // If no predictions for today, generate them
    if (!data || data.length === 0) {
      console.log(`[SpatialForecast] No predictions for today, generating...`);
      const forecast = await generateForecast(timeHorizon);
      return forecast;
    }
    
    // Check if cached predictions have the correct grid cell size (100m)
    // If not, regenerate to ensure consistency
    const hasCorrectGridSize = data.some(r => r.region_radius_meters === 100);
    if (!hasCorrectGridSize) {
      console.log(`[SpatialForecast] Cached predictions have old grid size, regenerating...`);
      const forecast = await generateForecast(timeHorizon);
      return forecast;
    }
    
    // Transform database data to match forecast structure
    const region_analyses = {};
    const features = [];
    
    // Use current grid cell size from config (100m) instead of stored value
    const CURRENT_GRID_CELL_SIZE = 100; // Should match Python config GRID_CELL_SIZE_METERS
    
    for (const record of data) {
      region_analyses[record.region_id] = {
        region_id: record.region_id,
        risk_score: record.risk_score,
        risk_level: record.risk_level,
        is_hotspot: record.risk_score > 0,
        report_count: record.report_count,
        gi_star: record.gi_statistic,
        p_value: record.p_value,
        is_significant: record.is_significant,
        region_center_lat: record.region_center_lat,
        region_center_lng: record.region_center_lng,
        region_radius_meters: CURRENT_GRID_CELL_SIZE
      };
      
      // Add GeoJSON feature for grid cells
      if (record.risk_score > 0) {
        const radius_deg = CURRENT_GRID_CELL_SIZE / 111000.0;
        const polygon_coords = [
          [
            [record.region_center_lng - radius_deg, record.region_center_lat - radius_deg],
            [record.region_center_lng + radius_deg, record.region_center_lat - radius_deg],
            [record.region_center_lng + radius_deg, record.region_center_lat + radius_deg],
            [record.region_center_lng - radius_deg, record.region_center_lat + radius_deg],
            [record.region_center_lng - radius_deg, record.region_center_lat - radius_deg]
          ]
        ];
        
        features.push({
          type: 'Feature',
          geometry: {
            type: 'Polygon',
            coordinates: polygon_coords
          },
          properties: {
            region_id: record.region_id,
            risk_score: record.risk_score,
            risk_level: record.risk_level,
            report_count: record.report_count,
            gi_star: record.gi_statistic,
            p_value: record.p_value,
            center_lat: record.region_center_lat,
            center_lng: record.region_center_lng,
            fillColor: record.risk_level === 'high' ? '#ff0000' : record.risk_level === 'medium' ? '#ffff00' : '#00ff00',
            fillOpacity: 0.5
          }
        });
      }
    }
    
    const hotspot_count = data.filter(r => r.risk_score > 0).length;

    // Fetch the real total reports for this time horizon directly from the reports table
    const timeHorizonDays = { 'daily': 1, 'weekly': 7, 'monthly': 30 };
    const days = timeHorizonDays[timeHorizon] || 7;
    const startDate = new Date();
    startDate.setDate(startDate.getDate() - days);
    
    const { count } = await supabaseAdmin
      .from('reports')
      .select('*', { count: 'exact', head: true })
      .gte('created_at', startDate.toISOString());
      
    const total_reports = count || 0;
    
    return {
      time_horizon: timeHorizon,
      prediction_date: today,
      total_regions: data.length,
      hotspot_count: hotspot_count,
      total_reports: total_reports,
      region_analyses: region_analyses,
      geojson: {
        type: 'FeatureCollection',
        features: features
      },
      heatmap_geojson: null // Heatmap not available from database cache
    };
    
  } catch (error) {
    console.error('[SpatialForecast] Error getting current predictions:', error);
    throw error;
  }
};

/**
 * Get prediction accuracy metrics
 */
export const getAccuracyMetrics = async (timeHorizon = null) => {
  try {
    let query = supabaseAdmin
      .from('hotspot_accuracy')
      .select('*')
      .order('evaluation_date', { ascending: false });
    
    if (timeHorizon) {
      query = query.eq('time_horizon', timeHorizon);
    }
    
    const { data, error } = await query;
    
    if (error) throw error;
    
    // Calculate aggregate metrics
    if (data && data.length > 0) {
      const avgAccuracy = data.reduce((sum, record) => sum + record.accuracy_score, 0) / data.length;
      
      return {
        records: data,
        averageAccuracy: avgAccuracy,
        totalEvaluations: data.length
      };
    }
    
    return {
      records: [],
      averageAccuracy: 0,
      totalEvaluations: 0
    };
    
  } catch (error) {
    console.error('[SpatialForecast] Error getting accuracy metrics:', error);
    throw error;
  }
};
