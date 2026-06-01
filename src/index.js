// Main entry point for the EcoPin backend API server. Initializes the Express app and starts the server.

import app from './app.js';
import { PORT as _PORT, NODE_ENV, NEXT_PUBLIC_SUPABASE_URL } from './config/index.js';

const PORT = _PORT || 3000;

const server = app.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
    console.log(`Environment: ${NODE_ENV}`);
    console.log(`Supabase URL: ${NEXT_PUBLIC_SUPABASE_URL}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('SIGTERM signal received: closing HTTP server');
    server.close(() => {
        console.log('HTTP server closed');
    });
});
