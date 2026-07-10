import { supabase, supabaseAdmin } from "../config/supabase.config.js";
import { VALID_IMAGE_MIME_TYPES, VALID_IMAGE_EXTENSIONS, PROFILE_FILE_SIZE } from "../config/index.js";

export const getProfile = async (req, res, next) => {
    try {
        const userId = req.user.id;

        const { data, error } = await supabaseAdmin
            .from('profiles')
            .select('*')
            .eq('id', userId)
            .single();

        if (error) {
            return res.status(404).json({
                message: 'Profile not found',
                error: error.message
            });
        }

        res.status(200).json({
            profile: data
        });
    } catch (error) {
        next(error);
    }
};

export const updateProfile = async (req, res, next) => {
    try {
        const userId = req.user.id;
        const { full_name, email, avatar_url } = req.body;

        const updateData = {};
        if (full_name !== undefined) updateData.full_name = full_name;
        if (email !== undefined) updateData.email = email;
        if (avatar_url !== undefined) updateData.avatar_url = avatar_url;

        const { data, error } = await supabaseAdmin
            .from('profiles')
            .update(updateData)
            .eq('id', userId)
            .select('*')
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to update profile',
                error: error.message
            });
        }

        res.status(200).json({
            message: 'Profile updated successfully',
            profile: data
        });
    } catch (error) {
        next(error);
    }
};

export const uploadAvatar = async (req, res, next) => {
    try {
        const file = req.file;
        if (!file) {
            return res.status(400).json({
                message: 'No file uploaded'
            });
        }

        // Validate file size
        if (file.size > PROFILE_FILE_SIZE) {
            return res.status(400).json({
                message: `File size too large. Maximum allowed is ${PROFILE_FILE_SIZE / (1024 * 1024)}MB`
            });
        }

        // Validate file mimetype
        if (!VALID_IMAGE_MIME_TYPES.includes(file.mimetype)) {
            return res.status(400).json({
                message: 'Invalid file type. Only JPEG, JPG, PNG, and WEBP are allowed.'
            });
        }

        // Validate file extension
        const fileExt = file.originalname.split('.').pop()?.toLowerCase();
        if (!fileExt || !VALID_IMAGE_EXTENSIONS.includes(fileExt)) {
            return res.status(400).json({
                message: 'Invalid file extension. Only JPEG, JPG, PNG, and WEBP are allowed.'
            });
        }

        const userId = req.user.id;
        const fileName = `${userId}/avatar.${fileExt}`;

        // Delete old avatar if exists
        try {
            await supabaseAdmin.storage
                .from('avatars')
                .remove([`${userId}/avatar.jpg`, `${userId}/avatar.png`, `${userId}/avatar.webp`]);
        } catch (err) {
            // Ignore error if old file doesn't exist
        }

        // Upload new avatar
        const { data: uploadData, error: uploadError } = await supabaseAdmin.storage
            .from('avatars')
            .upload(fileName, file.buffer, {
                contentType: file.mimetype,
                upsert: true
            });

            if (uploadError) {
            return res.status(400).json({
                message: 'Failed to upload avatar',
                error: uploadError.message
            });
        }

        // Get public URL
        const { data: { publicUrl } } = supabaseAdmin.storage
            .from('avatars')
            .getPublicUrl(fileName);

        // Update profile with new avatar URL
        const { data: profileData, error: profileError } = await supabaseAdmin
            .from('profiles')
            .update({ avatar_url: publicUrl })
            .eq('id', userId)
            .select('*')
            .single();

        if (profileError) {
            return res.status(400).json({
                message: 'Failed to update profile with avatar',
                error: profileError.message
            });
        }

        res.status(200).json({
            message: 'Avatar uploaded successfully',
            profile: profileData
        });
    } catch (error) {
        next(error);
    }
};

export const updateDataConsent = async (req, res, next) => {
    try {
        const userId = req.user.id;
        const { data_consent } = req.body;

        console.log("Data Consent Given: ", data_consent)

        // Validate input
        if (typeof data_consent !== "boolean") {
            return res.status(400).json({
                message: "data_consent must be a boolean value."
            });
        }
        const { data, error } = await supabaseAdmin
            .from("profiles")
            .update({ data_consent })
            .eq("id", userId)
            .select("*")
            .single();

        if (error) {
            console.log(error);
            return res.status(400).json({
                message: "Failed to update data consent.",
                error: error.message
            });
        }

        res.status(200).json({
            message: "Data consent updated successfully.",
            profile: data
        });
    } catch (error) {
        next(error);
    }
};