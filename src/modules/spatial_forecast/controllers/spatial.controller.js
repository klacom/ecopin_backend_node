// Spatial Forecast Controller
// Handles HTTP requests for hotspot forecasting

import { 
  generateForecast, 
  getPredictions, 
  getCurrentPredictions,
  getAccuracyMetrics,
  getAvailableDates 
} from '../services/spatialClient.service.js';

/**
 * Manually trigger forecast generation
 */
export const triggerForecast = async (req, res, next) => {
  try {
    const { time_horizon = 'weekly', bounding_box } = req.body;
    
    const result = await generateForecast(time_horizon, bounding_box);
    
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
      timeHorizon: req.query.time_horizon,
      clusterId: req.query.cluster_id,
      startDate: req.query.start_date,
      endDate: req.query.end_date,
      isSignificant: req.query.is_significant === 'true' ? true : 
                     req.query.is_significant === 'false' ? false : undefined,
      limit: req.query.limit ? parseInt(req.query.limit) : undefined
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
    const { horizon = 'weekly' } = req.params;
    
    const predictions = await getCurrentPredictions(horizon);
    
    res.status(200).json({
      message: 'Current predictions fetched successfully',
      data: predictions,
      count: Array.isArray(predictions) ? predictions.length : Object.keys(predictions).length
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
    const { time_horizon } = req.query;
    
    const metrics = await getAccuracyMetrics(time_horizon);
    
    res.status(200).json({
      message: 'Accuracy metrics fetched successfully',
      data: metrics
    });
  } catch (error) {
    next(error);
  }
};

/**
 * Get available prediction dates
 */
export const fetchAvailableDates = async (req, res, next) => {
  try {
    const dates = await getAvailableDates();
    
    res.status(200).json({
      message: 'Available dates fetched successfully',
      data: dates
    });
  } catch (error) {
    next(error);
  }
};
