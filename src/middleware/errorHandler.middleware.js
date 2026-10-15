// Global error handler middleware for the EcoPin backend API server.

export const errorHandler = (err, req, res, next) => {
    console.error(err?.stack || err);

    const status = err?.statusCode || (typeof err?.status === 'number' ? err.status : 500);
    const message = err?.message || (typeof err === 'string' ? err : 'Internal Server Error');

    res.status(status).json({
        message,
        error: message,
        stack: process.env.NODE_ENV === 'development' ? err?.stack : undefined,
    });
};
