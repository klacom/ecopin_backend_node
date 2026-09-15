// Spatial Forecast Routes
import express from 'express';
import { triggerForecast, fetchPredictions, fetchCurrentPredictions, fetchAccuracyMetrics } from '../controllers/spatial.controller.js';
import { authenticate, authorize } from '../../../middleware/auth.middleware.js';

const router = express.Router();

// All routes require authentication
router.use(authenticate);

// Generate forecast (admin/officer only)
router.post('/generate', authorize(['admin', 'officer']), triggerForecast);

// Fetch historical predictions (admin/officer only)
router.get('/predictions', authorize(['admin', 'officer']), fetchPredictions);

// Get current predictions for a time horizon (admin/officer only)
router.get('/current/:horizon', authorize(['admin', 'officer']), fetchCurrentPredictions);

// Get accuracy metrics (admin/officer only)
router.get('/accuracy', authorize(['admin', 'officer']), fetchAccuracyMetrics);

export default router;
