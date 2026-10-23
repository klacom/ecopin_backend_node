import express from 'express';
import {
    rateLimiter,
    authRateLimiter,
    resolveGeneralRateLimitKey,
    resolveAuthRateLimitKey,
} from '../src/middleware/rateLimit.middleware.js';

describe('Rate limiting and proxy isolation', () => {
    test('resolveGeneralRateLimitKey isolates distinct Bearer tokens behind a shared BFF proxy IP', () => {
        const reqA = {
            ip: '127.0.0.1',
            headers: { authorization: 'Bearer token-officer-a' },
        };
        const reqB = {
            ip: '127.0.0.1',
            headers: { authorization: 'Bearer token-officer-b' },
        };
        const reqAnon = {
            ip: '127.0.0.1',
            headers: {},
        };

        expect(resolveGeneralRateLimitKey(reqA)).not.toEqual(resolveGeneralRateLimitKey(reqB));
        expect(resolveGeneralRateLimitKey(reqA)).toMatch(/^bearer:/);
        expect(resolveGeneralRateLimitKey(reqAnon)).toMatch(/^ip:/);
    });

    test('resolveAuthRateLimitKey isolates login attempts by normalized email on a shared proxy IP', () => {
        const attackerReq = {
            ip: '127.0.0.1',
            body: { email: 'attacker@example.com' },
        };
        const officerReq = {
            ip: '127.0.0.1',
            body: { email: 'Officer@PasigCity.gov.ph ' },
        };
        const officerReqLower = {
            ip: '127.0.0.1',
            body: { email: 'officer@pasigcity.gov.ph' },
        };

        expect(resolveAuthRateLimitKey(attackerReq)).not.toEqual(resolveAuthRateLimitKey(officerReq));
        expect(resolveAuthRateLimitKey(officerReq)).toEqual(resolveAuthRateLimitKey(officerReqLower));
    });

    test('authRateLimiter blocks repeated failures for one account without blocking another officer behind the same proxy', async () => {
        const app = express();
        app.set('trust proxy', 2);
        app.use(express.json());
        app.use('/api', rateLimiter);
        app.post('/api/auth/login', authRateLimiter, (req, res) => {
            if (req.body.password === 'valid-password') {
                return res.status(200).json({ ok: true });
            }
            return res.status(401).json({ error: 'Invalid credentials' });
        });
        app.use((req, res) => res.status(404).json({ error: 'Route not found' }));

        const server = await new Promise((resolve) => {
            const s = app.listen(0, '127.0.0.1', () => resolve(s));
        });
        const baseUrl = `http://127.0.0.1:${server.address().port}`;

        try {
            // Non-API scanner probes hit 404 without tripping rateLimiter
            for (let i = 0; i < 15; i++) {
                const scanRes = await fetch(`${baseUrl}/wp-content/scan-${i}.php`, {
                    headers: { 'X-Forwarded-For': '203.0.113.10, 127.0.0.1' },
                });
                expect(scanRes.status).toBe(404);
            }

            // Exhaust failed login attempts for attacker@example.com
            for (let i = 0; i < 10; i++) {
                const failRes = await fetch(`${baseUrl}/api/auth/login`, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'X-Forwarded-For': '198.51.100.25, 127.0.0.1',
                    },
                    body: JSON.stringify({ email: 'attacker@example.com', password: 'wrong' }),
                });
                expect(failRes.status).toBe(401);
            }

            const blockedRes = await fetch(`${baseUrl}/api/auth/login`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-Forwarded-For': '198.51.100.25, 127.0.0.1',
                },
                body: JSON.stringify({ email: 'attacker@example.com', password: 'wrong' }),
            });
            expect(blockedRes.status).toBe(429);

            // Officer logging in through the exact same proxy IP still succeeds
            const officerRes = await fetch(`${baseUrl}/api/auth/login`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-Forwarded-For': '198.51.100.25, 127.0.0.1',
                },
                body: JSON.stringify({ email: 'officer@pasigcity.gov.ph', password: 'valid-password' }),
            });
            expect(officerRes.status).toBe(200);
        } finally {
            await new Promise((resolve) => server.close(resolve));
        }
    });
});
