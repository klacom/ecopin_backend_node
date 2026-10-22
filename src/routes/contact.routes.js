import { Router } from 'express';
import { sendContactEmail } from '../controllers/contact.controller.js';
import { getCmsSettingsService } from '../services/cms.service.js';
import { contactRateLimiter } from '../middleware/rateLimit.middleware.js';

const router = Router();

// Public CMS and contact info endpoint
router.get('/settings', async (req, res, next) => {
    try {
        const settings = await getCmsSettingsService();
        res.status(200).json(settings);
    } catch (error) {
        next(error);
    }
});

router.post('/send', contactRateLimiter, sendContactEmail);

export default router;

