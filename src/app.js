// Main application file for the EcoPin backend API server. Sets up Express, middleware, and routes.

import express, { json, urlencoded } from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import { FRONTEND_URL } from './config/index.js';

// Import routes
import authRoutes from './routes/auth.routes.js';
// import userRoutes from './routes/user.routes';
// import adminRoutes from './routes/admin.routes';

// Import middleware
import { errorHandler } from './middleware/errorHandler.middleware.js';
import { rateLimiter } from './middleware/rateLimit.middleware.js';

const app = express();

// Global middleware
app.use(helmet()); // Security headers
app.use(cors({
    origin: FRONTEND_URL || 'http://localhost:3001', // Flutter web dev server
    credentials: true,
}));
app.use(json({ limit: '10mb' }));
app.use(urlencoded({ extended: true }));
app.use(morgan('combined')); // Logging

// Apply rate limiting to all routes
app.use(rateLimiter);

// Health check endpoint
app.get('/health', (req, res) => {
    res.json({ status: 'OK', timestamp: new Date().toISOString() });
});

// Routes
app.use('/api/auth', authRoutes);
// app.use('/api/users', userRoutes);
// app.use('/api/admin', adminRoutes);

// 404 handler
app.use((req, res) => {
    res.status(404).json({ error: 'Route not found' });
});

// Global error handler (must be last)
app.use(errorHandler);

export default app;