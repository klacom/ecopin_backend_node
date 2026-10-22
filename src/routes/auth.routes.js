import { Router } from 'express';
import { register, login, logout, refreshToken, forgotPassword, resetPassword, getMe, changePassword, forceChangePassword, validateSession, verifyEmail, resendVerification, getPasswordRequirements, deleteAccount } from '../controllers/auth.controller.js';
import { validateRegistration, validateLogin } from '../middleware/validation.middleware.js';
import { authenticate, optionalAuthenticate, checkUserSuspension } from '../middleware/auth.middleware.js';
import { rateLimiter, authRateLimiter } from '../middleware/rateLimit.middleware.js';

const router = Router();

router.post('/register', authRateLimiter, validateRegistration, register);
router.post('/login', authRateLimiter, validateLogin, login);
router.get('/me', authenticate, checkUserSuspension, getMe);
router.post('/logout', authenticate, logout);
router.post('/refresh-token', refreshToken);
router.post('/forgot-password', authRateLimiter, forgotPassword);
router.post('/reset-password', authRateLimiter, resetPassword);
router.put('/change-password', authenticate, checkUserSuspension, changePassword);
router.post('/force-change-password', authenticate, checkUserSuspension, forceChangePassword);
router.get('/validate-session', validateSession); // No authenticate middleware - validates token directly
router.get('/verify-email', rateLimiter, verifyEmail);
router.post('/resend-verification', authRateLimiter, resendVerification);
router.get('/password-requirements', getPasswordRequirements);
router.delete('/delete-account', optionalAuthenticate, deleteAccount);
router.post('/delete-account', optionalAuthenticate, authRateLimiter, deleteAccount);
router.delete('/account', optionalAuthenticate, deleteAccount);

export default router;