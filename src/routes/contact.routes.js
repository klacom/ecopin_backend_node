import { Router } from 'express';
import { sendContactEmail } from '../controllers/contact.controller.js';
import { rateLimiter } from '../middleware/rateLimit.middleware.js';

const router = Router();

router.post('/send', rateLimiter, sendContactEmail);

export default router;
