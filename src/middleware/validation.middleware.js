// Validation middleware for the EcoPin backend API server. Uses express-validator to define validation rules for incoming requests related to user registration and login. Ensures that required fields are present and meet specified criteria (e.g., valid email format, password strength) before allowing the request to proceed to the corresponding controller functions.

import { body, validationResult } from 'express-validator';
import { MIN_PASSWORD_LENGTH } from '../config/index.js';

export const validateRegistration = [
    body('email').isEmail().normalizeEmail().withMessage('Valid email is required'),
    body('password')
        .isLength({ min: MIN_PASSWORD_LENGTH })
        .withMessage(`Password must be at least ${MIN_PASSWORD_LENGTH} characters`)
        .matches(/[A-Z]/).withMessage('Password must contain an uppercase letter')
        .matches(/[0-9]/).withMessage('Password must contain a number'),
    body('confirmPassword')
        .custom((value, { req }) => value === req.body.password)
        .withMessage('Passwords do not match'),
    (req, res, next) => {
        const errors = validationResult(req);
        if (!errors.isEmpty()) {
            return res.status(400).json({ errors: errors.array() });
        }
        next();
    },
];

export const validateLogin = [
    body('email').isEmail().normalizeEmail(),
    body('password').notEmpty(),
    (req, res, next) => {
        const errors = validationResult(req);
        if (!errors.isEmpty()) {
            return res.status(400).json({ errors: errors.array() });
        }
        next();
    },
];