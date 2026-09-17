import { Router } from 'express';
import { register, login, logout, refreshToken, forgotPassword, resetPassword, getMe, changePassword, validateSession } from '../controllers/auth.controller.js';
import { validateRegistration, validateLogin } from '../middleware/validation.middleware.js';
import { authenticate, checkUserSuspension } from '../middleware/auth.middleware.js';

const router = Router();

router.post('/register', validateRegistration, register);
router.post('/login', validateLogin, login);
router.get('/me', authenticate, checkUserSuspension, getMe);
router.post('/logout', logout);
router.post('/refresh-token', refreshToken);
router.post('/forgot-password', forgotPassword);
router.post('/reset-password', resetPassword);
router.put('/change-password', authenticate, checkUserSuspension, changePassword);
router.get('/validate-session', validateSession); // No authenticate middleware - validates token directly

export default router;