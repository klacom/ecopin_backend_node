import { jest } from '@jest/globals';
import express from 'express';
import { once } from 'node:events';

const sendMail = jest.fn();
jest.unstable_mockModule('../src/config/email.config.js', () => ({ transporter: { sendMail } }));
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({ supabase: {}, supabaseAdmin: {} }));
const errors = jest.spyOn(console, 'error').mockImplementation(() => {});
const contactRoutes = (await import('../src/routes/contact.routes.js')).default;
const { rateLimiter } = await import('../src/middleware/rateLimit.middleware.js');

afterAll(() => errors.mockRestore());
test('contact import is side-effect free and a real request gets the intended independent limiter', async () => {
  // The old controller invoked an Express middleware with an options object at import.
  await new Promise(resolve => setImmediate(resolve));
  expect(errors).not.toHaveBeenCalled();
  const app = express();
  app.use(express.json());
  app.use(rateLimiter);
  app.use('/api/contact', contactRoutes);
  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const url = `http://127.0.0.1:${server.address().port}/api/contact/send`;
    for (let i = 0; i < 3; i++) {
      const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
      expect(res.status).toBe(400);
      expect(res.headers.get('ratelimit-limit')).toBe('3');
      await res.arrayBuffer();
    }
    const blocked = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    expect(blocked.status).toBe(429);
    await blocked.arrayBuffer();
    expect(errors).not.toHaveBeenCalled();
    expect(sendMail).not.toHaveBeenCalled();
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});
