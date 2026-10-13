import { jest } from '@jest/globals';
import express from 'express';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { rateLimiter, operationalRateLimiter } from '../src/middleware/rateLimit.middleware.js';
import { RATE_LIMIT_MAX_REQUESTS, OPS_RATE_LIMIT_MAX_REQUESTS } from '../src/config/index.js';

describe('Tiered Rate Limiter Configuration and Routing', () => {
  test('configuration exports higher operational thresholds', () => {
    expect(typeof RATE_LIMIT_MAX_REQUESTS).toBe('number');
    expect(typeof OPS_RATE_LIMIT_MAX_REQUESTS).toBe('number');
    expect(OPS_RATE_LIMIT_MAX_REQUESTS).toBeGreaterThanOrEqual(RATE_LIMIT_MAX_REQUESTS);
  });

  test('rateLimiter skips /api/optimization requests', async () => {
    const app = express();
    app.use(rateLimiter);
    app.get('/api/optimization/options', (req, res) => res.json({ ok: true }));
    app.get('/api/reports', (req, res) => res.json({ ok: true }));

    const server = createServer(app);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const port = server.address().port;

    try {
      // Send request to /api/optimization/options
      const resOpt = await fetch(`http://127.0.0.1:${port}/api/optimization/options`);
      expect(resOpt.status).toBe(200);
      // Because it skipped rateLimiter, Ratelimit headers from rateLimiter are omitted
      expect(resOpt.headers.get('ratelimit-limit')).toBeNull();

      // Send request to /api/reports
      const resReports = await fetch(`http://127.0.0.1:${port}/api/reports`);
      expect(resReports.status).toBe(200);
      // rateLimiter applies to /api/reports
      expect(resReports.headers.get('ratelimit-limit')).not.toBeNull();
    } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    }
  });

  test('operationalRateLimiter applies dedicated rate limit headers to operational routes', async () => {
    const app = express();
    app.use('/api/optimization', operationalRateLimiter, (req, res) => res.json({ ok: true }));

    const server = createServer(app);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const port = server.address().port;

    try {
      const res = await fetch(`http://127.0.0.1:${port}/api/optimization/runs`);
      expect(res.status).toBe(200);
      expect(res.headers.get('ratelimit-limit')).toBe(String(OPS_RATE_LIMIT_MAX_REQUESTS));
      expect(Number(res.headers.get('ratelimit-remaining'))).toBeLessThanOrEqual(OPS_RATE_LIMIT_MAX_REQUESTS);
    } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    }
  });
});
