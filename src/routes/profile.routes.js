import express from 'express';
import { getProfile, updateProfile, uploadAvatar } from '../controllers/profile.controller.js';
import { authenticate } from '../middleware/auth.middleware.js';
import multer from 'multer';

const router = express.Router();

// Configure multer for in-memory storage
const storage = multer.memoryStorage();
const upload = multer({
    storage: storage,
    limits: {
        fileSize: 5 * 1024 * 1024, // 5MB
    },
    fileFilter: (req, file, cb) => {
        if (file.mimetype.startsWith('image/')) {
            cb(null, true);
        } else {
            cb(new Error('Only image files are allowed!'), false);
        }
    }
});

// All profile routes require authentication
router.use(authenticate);

router.get('/', getProfile);
router.put('/', updateProfile);
router.post('/avatar', upload.single('avatar'), uploadAvatar);

export default router;