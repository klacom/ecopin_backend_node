// Spatial Forecast Controller
// Handles HTTP requests for hotspot forecasting

import { 
  generateForecast, 
  getPredictions, 
  getCurrentPredictions,
  getAccuracyMetrics,
  getAvailableDates,
  getZoneTrend
} from '../services/spatialClient.service.js';

/**
 * Manually trigger forecast generation
 */
export const triggerForecast = async (req, res, next) => {
  try {
    const body = req.body ?? {};
    if (body.bounding_box != null || (body.zone_type !== undefined && body.zone_type !== 'h3')) {
      return res.status(400).json({ error: 'Forecasts use the complete stable H3 zone catalog' });
    }
    const result = await generateForecast(body.horizon ?? body.time_horizon ?? '30d');
    
    res.status(200).json({
      message: 'Forecast generated successfully',
      data: result
    });
  } catch (error) {
    next(error);
  }
};

/**
 * Fetch historical predictions
 */
export const fetchPredictions = async (req, res, next) => {
  try {
    const filters = {
      timeHorizon: req.query.horizon ?? req.query.time_horizon,
      regionId: req.query.zone_id ?? req.query.region_id,
      startDate: req.query.start_date,
      endDate: req.query.end_date,
      isSignificant: req.query.is_significant === 'true' ? true : 
                     req.query.is_significant === 'false' ? false : undefined,
      limit: req.query.limit === undefined ? undefined : Number(req.query.limit)
    };
    
    const predictions = await getPredictions(filters);
    
    res.status(200).json({
      message: 'Predictions fetched successfully',
      data: predictions,
      count: predictions.length
    });
  } catch (error) {
    next(error);
  }
};

/**
 * Get current predictions for a time horizon
 */
export const fetchCurrentPredictions = async (req, res, next) => {
  try {
    const horizon = req.query.horizon ?? req.params.horizon ?? '30d';
    
    const predictions = await getCurrentPredictions(horizon);
    
    res.status(200).json({
      message: 'Current predictions fetched successfully',
      data: predictions,
      count: predictions.total_regions
    });
  } catch (error) {
    next(error);
  }
};

/**
 * Get prediction accuracy metrics
 */
export const fetchAccuracyMetrics = async (req, res, next) => {
  try {
    const metrics = await getAccuracyMetrics(req.query.horizon ?? req.query.time_horizon ?? null);
    
    res.status(200).json({
      message: 'Accuracy metrics fetched successfully',
      data: metrics
    });
  } catch (error) {
    next(error);
  }
};

export const fetchZoneTrend = async (req, res, next) => {
  try {
    const result = await getZoneTrend(req.params.zoneId, req.query.horizon ?? '30d');
    res.status(200).json({ message: 'Zone trend fetched successfully', data: result });
  } catch (error) {
    next(error);
  }
};

/**
 * Get available prediction dates
 */
export const fetchAvailableDates = async (req, res, next) => {
  try {
    const dates = await getAvailableDates(req.query.horizon ?? req.query.time_horizon ?? null);
    
    res.status(200).json({
      message: 'Available dates fetched successfully',
      data: dates
    });
  } catch (error) {
    next(error);
  }
};
