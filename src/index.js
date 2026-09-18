// Main entry point for the EcoPin backend API server.

import app from './app.js';
import { PORT as _PORT, NODE_ENV, NEXT_PUBLIC_SUPABASE_URL } from './config/index.js';
import { startAllSchedules } from './modules/spatial_forecast/services/forecastScheduler.service.js';

const PORT = _PORT || 3000;

console.log('Starting server initialization...');

const server = app.listen(PORT, "0.0.0.0", () => {
    console.log(`Server running on ${PORT}`);
    console.log(`Environment: ${NODE_ENV}`);
    console.log(`Supabase URL: ${NEXT_PUBLIC_SUPABASE_URL}`);
    console.log('Server successfully started and listening');
});

server.on('error', (error) => {
    console.error('Server error:', error);
    process.exit(1);
});

// Start background cron jobs
startAllSchedules();

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('SIGTERM signal received: closing HTTP server');
    server.close(() => {
        console.log('HTTP server closed');
    });
});

process.on('SIGINT', () => {
    console.log('SIGINT signal received: closing HTTP server');
    server.close(() => {
        console.log('HTTP server closed');
        process.exit(0);
    });
});

// Handle unhandled rejections
process.on('unhandledRejection', (reason, promise) => {
    console.error('Unhandled Rejection at:', promise, 'reason:', reason);
});

// Handle uncaught exceptions
process.on('uncaughtException', (error) => {
    console.error('Uncaught Exception:', error);
});

console.log('Server initialization complete, waiting for connections...');
