import { randomUUID } from 'node:crypto';
import { dispatchApmAlert, classifyErrorSeverity } from '../services/apm-monitoring.service.js';

// Global error handler middleware for the EcoPin backend API server.

export const errorHandler = (err, req, res, next) => {
    const status = err?.statusCode || (typeof err?.status === 'number' ? err.status : (err?.code === 'LIMIT_FILE_SIZE' ? 413 : (err?.name === 'MulterError' ? 400 : 500)));
    const requestId = randomUUID();

    console.error('Request failed', {
        requestId, status,
        ...(err?.photoOperation ? {
            operation: err.photoOperation,
            reportId: req?.params?.id,
            method: req?.method,
            code: err.code,
            message: err.message,
            // Constraint errors can include the entire report row.
            details: err.details?.replace(/Failing row contains[\s\S]*/i, 'Failing row values omitted.'),
            hint: err.hint,
        } : {}),
    });

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

    const responseBody = {
        message: err?.publicMessage || (err?.statusCode === 409 && err?.message ? err.message : 'Request failed'),
        error: 'Request failed',
        requestId,
    };
    if (err?.publicCode) responseBody.code = err.publicCode;
    if (err?.serverRecord) {
        responseBody.report = err.serverRecord;
        responseBody.server_record = err.serverRecord;
    }

    res.status(status).json(responseBody);
};
