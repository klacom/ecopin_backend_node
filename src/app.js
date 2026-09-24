// Main application file for the EcoPin backend API server. Sets up Express, middleware, and routes.

import express, { json, urlencoded } from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { FRONTEND_URL } from './config/index.js';

const execFileAsync = promisify(execFile);

// Import routes
import authRoutes from './routes/auth.routes.js';
import reportRoutes from './routes/report.routes.js';
import { clusterRoutes } from './modules/clustering/index.js';
import { spatialRoutes } from './modules/spatial_forecast/index.js';
import { optimizationRoutes } from './modules/optimization/index.js';
import profileRoutes from './routes/profile.routes.js';
import cleanupTaskRoutes from './routes/cleanup_task.routes.js';
import adminRoutes from './routes/admin.routes.js';
import responseLogRoutes from './routes/response_log.routes.js';
import strikeRoutes from './routes/strike.routes.js';
import manualReviewRoutes from './routes/manualReview.routes.js';

// Import middleware
import { errorHandler } from './middleware/errorHandler.middleware.js';
import { rateLimiter } from './middleware/rateLimit.middleware.js';

const app = express();

// Global middleware
app.use(helmet()); // Security headers
app.use(cors({
    origin: function (origin, callback) {
        const allowedOrigins = [FRONTEND_URL, 'http://localhost:4001', 'https://ecopin-web.onrender.com'];
        // Allow if no origin (e.g. mobile apps, curl), or if in allowed list, or if it's a Vercel preview URL
        if (!origin || allowedOrigins.includes(origin) || origin.endsWith('.vercel.app')) {
            callback(null, true);
        } else {
            callback(new Error('Not allowed by CORS'));
        }
    },
    credentials: true,
}));
app.use(json({ limit: '10mb' }));
app.use(urlencoded({ extended: true }));
app.use(morgan('combined')); // Logging

// Apply rate limiting to all routes
app.use(rateLimiter);

// Health check endpoint
app.get('/health', async (req, res) => {
    const { supabase } = await import('./config/supabase.config.js');
    const { CLASSIFIER_SERVICE_URL } = await import('./config/index.js');

    const healthCheck = {
        status: 'OK',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        environment: process.env.NODE_ENV || 'development',
        dependencies: {
            database: 'unknown',
            ffmpeg: 'unknown',
            classifier: 'unknown'
        }
    };

    // Check ffmpeg availability
    try {
        await execFileAsync('ffmpeg', ['-version']);
        healthCheck.dependencies.ffmpeg = 'available';
    } catch (error) {
        healthCheck.dependencies.ffmpeg = 'unavailable';
        healthCheck.status = 'DEGRADED';
    }

    // Check classifier service availability
    try {
        if (CLASSIFIER_SERVICE_URL) {
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 5000);

            const response = await fetch(`${CLASSIFIER_SERVICE_URL}/health`, {
                signal: controller.signal
            }).catch(() => null);

            clearTimeout(timeout);

            if (response && response.ok) {
                healthCheck.dependencies.classifier = 'available';
            } else {
                healthCheck.dependencies.classifier = 'unavailable';
                healthCheck.status = 'DEGRADED';
            }
        } else {
            healthCheck.dependencies.classifier = 'not_configured';
        }
    } catch (error) {
        healthCheck.dependencies.classifier = 'error';
        healthCheck.status = 'DEGRADED';
    }

    // Check database connectivity
    try {
        const { error } = await supabase.from('profiles').select('id').limit(1);
        if (!error) {
            healthCheck.dependencies.database = 'available';
        } else {
            healthCheck.dependencies.database = 'error';
            healthCheck.status = 'DEGRADED';
        }
    } catch (error) {
        healthCheck.dependencies.database = 'error';
        healthCheck.status = 'DEGRADED';
    }

    const statusCode = healthCheck.status === 'OK' ? 200 : 503;
    res.status(statusCode).json(healthCheck);
});

// Routes
app.use('/api/auth', authRoutes);
app.use('/api/reports', reportRoutes);
app.use('/api/clusters', clusterRoutes);
app.use('/api/spatial-forecast', spatialRoutes);
app.use('/api/profile', profileRoutes);
app.use('/api/cleanup-tasks', cleanupTaskRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/response-logs', responseLogRoutes);
app.use('/api/strikes', strikeRoutes);
app.use('/api/manual-review', manualReviewRoutes);
app.use('/api/optimization', optimizationRoutes);

// 404 handler
app.use((req, res) => {
    res.status(404).json({ error: 'Route not found' });
});

// Global error handler (must be last)
app.use(errorHandler);

export default app;