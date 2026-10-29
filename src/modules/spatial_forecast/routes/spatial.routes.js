// Spatial Forecast Routes
import express from 'express';
import { fetchPatternAnalysis, triggerForecast, fetchPredictions, fetchCurrentPredictions, fetchAccuracyMetrics, fetchAvailableDates, fetchZoneTrend } from '../controllers/spatial.controller.js';
import { authenticate, authorize } from '../../../middleware/auth.middleware.js';

const router = express.Router();

// All routes require authentication
router.use(authenticate);

router.get('/patterns', authorize(['admin', 'officer']), fetchPatternAnalysis);

// Generate forecast (admin/officer only)
router.post('/generate', authorize(['admin', 'officer']), triggerForecast);

// Fetch historical predictions (admin/officer only)
router.get('/predictions', authorize(['admin', 'officer']), fetchPredictions);

// Get current predictions for a time horizon (admin/officer only)
router.get('/current/:horizon', authorize(['admin', 'officer']), fetchCurrentPredictions);
router.get('/forecast/current', authorize(['admin', 'officer']), fetchCurrentPredictions);
router.get('/predictions/current', authorize(['admin', 'officer']), fetchCurrentPredictions);
router.get('/zones/:zoneId/trend', authorize(['admin', 'officer']), fetchZoneTrend);
router.get('/zones/:zoneId/history', authorize(['admin', 'officer']), fetchZoneTrend);

// Get accuracy metrics (admin/officer only)
router.get('/accuracy', authorize(['admin', 'officer']), fetchAccuracyMetrics);

// Get available prediction dates
router.get('/available-dates', authorize(['admin', 'officer']), fetchAvailableDates);

export default router;
