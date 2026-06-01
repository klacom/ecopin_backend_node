// Authentication routes for the EcoPin backend API server. Defines endpoints for user registration, login, logout, token refresh, and password reset functionality. Each route is associated with a corresponding controller function that implements the business logic for handling authentication-related requests.

import { Router } from 'express';
import { register, login, logout, refreshToken, forgotPassword, resetPassword, getMe } from '../controllers/auth.controller.js';
import { validateRegistration, validateLogin } from '../middleware/validation.middleware.js';
import { authenticate } from '../middleware/auth.middleware.js';

const router = Router();

router.post('/register', validateRegistration, register);
router.post('/login', validateLogin, login);
router.get('/me', authenticate, getMe);
router.post('/logout', authenticate, logout);
router.post('/refresh-token', refreshToken);
router.post('/forgot-password', forgotPassword);
router.post('/reset-password', resetPassword);

export default router;