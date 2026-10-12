import {Router} from 'express';
import {authenticate,checkUserSuspension} from '../middleware/auth.middleware.js';
import {getStorageMedia} from '../controllers/media.controller.js';
const router=Router();
router.get('/storage',authenticate,checkUserSuspension,getStorageMedia);
export default router;
