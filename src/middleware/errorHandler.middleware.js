import { randomUUID } from 'node:crypto';
import { dispatchApmAlert, classifyErrorSeverity } from '../services/apm-monitoring.service.js';

// Global error handler middleware for the EcoPin backend API server.

export const errorHandler = (err, req, res, next) => {
    const status = err?.statusCode || (typeof err?.status === 'number' ? err.status : (err?.code === 'LIMIT_FILE_SIZE' ? 413 : (err?.name === 'MulterError' ? 400 : 500)));
    const requestId = randomUUID();

    console.error('Request failed', { requestId, status });

    if (status >= 500 || err?.code === 'ECONNREFUSED' || err?.code === 'ETIMEDOUT') {
        const severity = classifyErrorSeverity(err, { status, message: err?.message });
        try {
            dispatchApmAlert({
                error: err,
                eventType: status >= 500 ? 'UNCAUGHT_SERVER_ERROR' : 'SERVICE_FAILURE',
                service: 'ecopin-backend',
                area: req?.baseUrl || 'api',
                message: err?.message || 'Server error',
                actor: req?.user ? { id: req.user.id, role: req.user.role } : null,
                metadata: {
                    requestId,
                    status,
                    path: req?.path,
                    method: req?.method
                }
            }, { severity }).catch(() => {});
        } catch {
            // APM capture failure must never prevent response delivery
        }
    }

    res.status(status).json({
        message: 'Request failed',
        error: 'Request failed',
        requestId,
    });
};

