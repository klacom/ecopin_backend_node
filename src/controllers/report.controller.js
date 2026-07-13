import { supabaseAdmin as supabase } from "../config/supabase.config.js";
import multer from 'multer';
import exifParser from 'exif-parser';
import { validateImage } from '../services/imageValidation.service.js';
import { VALIDATION_STATUS, VALID_IMAGE_MIME_TYPES, VALID_IMAGE_EXTENSIONS, EVIDENCE_PHOTO_FILE_SIZE, REPORT_PHOTOS_STORAGE_PATH, BEFORE_AFTER_PHOTO_FILE_SIZE } from '../config/index.js';
import { clusterReports } from '../services/clustering.service.js';

// Configure multer for memory storage
const storage = multer.memoryStorage();
export const upload = multer({
    storage: storage,
    limits: { fileSize: EVIDENCE_PHOTO_FILE_SIZE },
    fileFilter: (req, file, cb) => {
        if (VALID_IMAGE_MIME_TYPES.includes(file.mimetype)) {
            cb(null, true);
        } else {
            cb(new Error('Invalid file type. Only JPEG, JPG, PNG, and WEBP are allowed.'), false);
        }
    }
});

// Configure multer for before/after photos
const beforeAfterStorage = multer.memoryStorage();
export const beforeAfterUpload = multer({
    storage: beforeAfterStorage,
    limits: { fileSize: BEFORE_AFTER_PHOTO_FILE_SIZE },
    fileFilter: (req, file, cb) => {
        if (VALID_IMAGE_MIME_TYPES.includes(file.mimetype)) {
            cb(null, true);
        } else {
            cb(new Error('Invalid file type. Only JPEG, JPG, PNG, and WEBP are allowed.'), false);
        }
    }
});

export const addReportNote = async (req, res, next) => {
    const { id } = req.params;
    const { note } = req.body;

    try {

        const { data, error } = await supabase
            .from('reports')
            .update({ notes: note })
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to add note',
                error: error.message
            });
        }

        res.status(200).json({
            message: 'Note added successfully',
            report: data
        });
    } catch (error) {
        next(error);
    }
};

// Upload before/after photo for report
export const uploadReportPhoto = async (req, res, next) => {
    const { id } = req.params;
    const { photo_type } = req.body; // 'before' or 'after'

    console.log('Uploading report photo:', { id, photo_type });

    if (!req.file) {
        return res.status(400).json({ message: 'No file uploaded' });
    }

    try {
        const timestamp = Date.now();
        const filename = `${timestamp}_${req.file.originalname}`;
        const filePath = `${id}/${photo_type}/${filename}`;

        console.log('File path:', filePath);
        console.log('Storage path:', REPORT_PHOTOS_STORAGE_PATH);

        // Upload to Supabase storage (Report Cleanup bucket)
        const { data: uploadData, error: uploadError } = await supabase
            .storage
            .from(REPORT_PHOTOS_STORAGE_PATH)
            .upload(filePath, req.file.buffer, {
                contentType: req.file.mimetype,
                upsert: false
            });

        if (uploadError) {
            console.error('Supabase upload error:', uploadError);
            return res.status(400).json({
                message: 'Failed to upload photo',
                error: uploadError.message
            });
        }

        console.log('Upload successful:', uploadData);

        // Get public URL
        const { data: urlData } = supabase
            .storage
            .from(REPORT_PHOTOS_STORAGE_PATH)
            .getPublicUrl(filePath);

        console.log('Public URL:', urlData.publicUrl);

        // Update the report with the photo URL
        const updateData = photo_type === 'before'
            ? { before_photo_url: urlData.publicUrl }
            : { after_photo_url: urlData.publicUrl };

        console.log('Updating report with:', updateData);

        const { data: reportData, error: reportError } = await supabase
            .from('reports')
            .update(updateData)
            .eq('id', id)
            .select()
            .single();

        if (reportError) {
            console.error('Database update error:', reportError);
            return res.status(400).json({
                message: 'Failed to update report with photo',
                error: reportError.message
            });
        }

        console.log('Report updated successfully:', reportData);

        res.status(200).json({
            message: 'Photo uploaded successfully',
            report: reportData
        });
    } catch (error) {
        console.error('Upload photo error:', error);
        next(error);
    }
};

// Delete before/after photo for report
export const deleteReportPhoto = async (req, res, next) => {
    const { id } = req.params;
    const { photo_type } = req.body; // 'before' or 'after'

    console.log('Deleting report photo:', { id, photo_type });

    try {
        // Get the current report to find the photo URL
        const { data: report, error: fetchError } = await supabase
            .from('reports')
            .select('*')
            .eq('id', id)
            .single();

        if (fetchError) {
            console.error('Failed to fetch report:', fetchError);
            return res.status(404).json({
                message: 'Report not found',
                error: fetchError.message
            });
        }

        const photoUrl = photo_type === 'before' ? report.before_photo_url : report.after_photo_url;

        if (!photoUrl) {
            return res.status(400).json({
                message: 'No photo to delete'
            });
        }

        // Extract the file path from the URL
        const urlParts = photoUrl.split('/');
        const fileName = urlParts[urlParts.length - 1];
        const filePath = `${id}/${photo_type}/${fileName}`;

        console.log('Deleting file path:', filePath);

        // Delete from Supabase storage
        const { error: deleteError } = await supabase
            .storage
            .from(REPORT_PHOTOS_STORAGE_PATH)
            .remove([filePath]);

        if (deleteError) {
            console.error('Failed to delete photo from storage:', deleteError);
            return res.status(400).json({
                message: 'Failed to delete photo from storage',
                error: deleteError.message
            });
        }

        console.log('Photo deleted from storage successfully');

        // Update the report to remove the photo URL
        const updateData = photo_type === 'before'
            ? { before_photo_url: null }
            : { after_photo_url: null };

        const { data: reportData, error: reportError } = await supabase
            .from('reports')
            .update(updateData)
            .eq('id', id)
            .select()
            .single();

        if (reportError) {
            console.error('Failed to update report:', reportError);
            return res.status(400).json({
                message: 'Failed to update report',
                error: reportError.message
            });
        }

        console.log('Report updated successfully:', reportData);

        res.status(200).json({
            message: 'Photo deleted successfully',
            report: reportData
        });
    } catch (error) {
        console.error('Delete photo error:', error);
        next(error);
    }
};

export const uploadEvidence = async (req, res, next) => {
    const { reportId } = req.params;
    const { latitude, longitude } = req.body;

    console.log('Uploading evidence for report:', reportId);
    console.log('File received:', req.file ? req.file.originalname : 'No file');

    if (!req.file) {
        return res.status(400).json({ message: 'No file uploaded' });
    }

    // Validate file extension
    const fileExt = req.file.originalname.split('.').pop()?.toLowerCase();
    if (!fileExt || !VALID_IMAGE_EXTENSIONS.includes(fileExt)) {
        return res.status(400).json({
            message: 'Invalid file extension. Only JPEG, JPG, PNG, and WEBP are allowed.'
        });
    }

    try {
        // List buckets to verify the correct bucket name
        const { data: buckets, error: bucketsError } = await supabase.storage.listBuckets();
        if (bucketsError) {
            console.error('Error listing buckets:', bucketsError);
        } else {
            console.log('Available buckets:', buckets.map(b => b.name));
        }
        // Extract EXIF metadata from image
        let imageMetadata = {
            latitude: null,
            longitude: null,
            timestamp: null
        };

        try {
            const parser = exifParser.create(req.file.buffer);
            const result = parser.parse();

            if (result.tags.GPSLatitude && result.tags.GPSLongitude) {
                // Convert EXIF GPS coordinates to decimal degrees
                const toDecimal = (degrees, minutes, seconds, direction) => {
                    let decimal = degrees + (minutes / 60) + (seconds / 3600);
                    if (direction === 'S' || direction === 'W') {
                        decimal = -decimal;
                    }
                    return decimal;
                };

                imageMetadata.latitude = toDecimal(
                    result.tags.GPSLatitude[0],
                    result.tags.GPSLatitude[1],
                    result.tags.GPSLatitude[2],
                    result.tags.GPSLatitudeRef
                );
                imageMetadata.longitude = toDecimal(
                    result.tags.GPSLongitude[0],
                    result.tags.GPSLongitude[1],
                    result.tags.GPSLongitude[2],
                    result.tags.GPSLongitudeRef
                );
            }

            if (result.tags.DateTimeOriginal) {
                imageMetadata.timestamp = result.tags.DateTimeOriginal;
            }
        } catch (exifError) {
            console.log('No EXIF data found:', exifError.message);
        }

        // Generate unique filename
        const timestamp = Date.now();
        const filename = `${timestamp}_${req.file.originalname}`;
        const filePath = `${reportId}/${filename}`;

        console.log('Uploading to path:', filePath);
        console.log('Bucket name: Report Evidence');

        // Upload to Supabase storage
        const { data: uploadData, error: uploadError } = await supabase
            .storage
            .from('Report Evidence')
            .upload(filePath, req.file.buffer, {
                contentType: req.file.mimetype,
                upsert: false
            });

        if (uploadError) {
            console.error('Upload error details:', JSON.stringify(uploadError, null, 2));
            console.error('Upload error message:', uploadError.message);
            console.error('Upload error status:', uploadError.statusCode);
            return res.status(400).json({
                message: 'Failed to upload image',
                error: uploadError.message,
                details: uploadError
            });
        }

        console.log('Upload successful:', uploadData);

        // Get public URL
        const { data: urlData } = supabase
            .storage
            .from('Report Evidence')
            .getPublicUrl(filePath);

        console.log('Public URL:', urlData.publicUrl);

        res.status(201).json({
            message: 'Evidence uploaded successfully',
            evidence: {
                url: urlData.publicUrl,
                path: filePath,
                metadata: imageMetadata
            }
        });
    } catch (error) {
        console.error('Error in uploadEvidence:', error);
        next(error);
    }
};

export const getReportEvidence = async (req, res, next) => {
    const { reportId } = req.params;

    try {
        console.log('Fetching evidence for report:', reportId);
        const { data, error } = await supabase
            .storage
            .from('Report Evidence')
            .list(reportId, {
                limit: 100,
                offset: 0,
                sortBy: { column: 'created_at', order: 'asc' }
            });

        if (error) {
            console.error('Error listing evidence:', error);
            return res.status(400).json({
                message: 'Failed to fetch evidence',
                error: error.message
            });
        }

        console.log('Evidence files found:', data);

        // Get public URLs for all files
        const evidence = data.map(file => {
            const { data: urlData } = supabase
                .storage
                .from('Report Evidence')
                .getPublicUrl(`${reportId}/${file.name}`);
            return {
                name: file.name,
                url: urlData.publicUrl,
                size: file.metadata?.size,
                createdAt: file.created_at
            };
        });

        console.log('Returning evidence:', evidence);
        res.status(200).json(evidence);
    } catch (error) {
        console.error('Error in getReportEvidence:', error);
        next(error);
    }
};

export const createReport = async (req, res, next) => {
    const {
        title,
        description,
        issue_type,
        latitude,
        longitude,
        on_private_property
    } = req.body;
    const user_id = req.user.id;
    const image = req.file;
    const onPrivateProperty =
        req.body.on_private_property === true ||
        req.body.on_private_property === "true";

    try {
        // Validate image if present
        if (image) {
            const fileExt = image.originalname.split('.').pop()?.toLowerCase();
            if (!fileExt || !VALID_IMAGE_EXTENSIONS.includes(fileExt)) {
                return res.status(400).json({
                    message: 'Invalid file extension. Only JPEG, JPG, PNG, and WEBP are allowed.'
                });
            }
        }

        let validationStatus = VALIDATION_STATUS.PENDING;
        let aiScore = 0;

        // If an image is provided, validate it using TensorFlow
        if (image) {
            // console.log("IMAGE BUFFER: ", image.buffer)
            const validation = await validateImage(image.buffer);
            aiScore = validation.score;
            validationStatus = validation.status;

            if (validationStatus === VALIDATION_STATUS.REJECTED) {
                return res.status(400).json({
                    message: 'Image validation failed. The image does not seem relevant to environmental issues.',
                    ai_score: aiScore,
                    details: validation.details
                });
            }
        }

        // PostGIS point format: 'POINT(longitude latitude)'
        const point = `POINT(${longitude} ${latitude})`;

        // console.log("IS ON PRIVATE PROPERTY: ", onPrivateProperty);
        // console.log("TYPE OF ON PRIVATE PROPERTY: ", typeof onPrivateProperty);

        // console.log(req.body.onPrivateProperty);
        // console.log(typeof req.body.onPrivateProperty);

        // Determine property owner consent status
        const propertyOwnerConsentStatus = onPrivateProperty ? 'pending' : 'not_required';

        const { data, error } = await supabase
            .from('reports')
            .insert({
                user_id,
                title,
                description,
                issue_type,
                location: point,
                on_private_property: onPrivateProperty,
                property_owner_consent_status: propertyOwnerConsentStatus,
                status: onPrivateProperty ? 'pending_owner_consent' : 'unresolved',
                validation_status: validationStatus
            })
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to create report',
                error: error.message
            });
        }

        res.status(201).json({
            message: 'Report created successfully',
            report: data,
            ai_score: aiScore
        });

        // Trigger clustering in the background (don't wait for it)
        clusterReports().catch(err => {
            console.error('Error in background clustering:', err);
        });
    } catch (error) {
        next(error);
    }
};

export const getMyReports = async (req, res, next) => {
    const user_id = req.user.id;

    try {
        const { data, error } = await supabase
            .from('reports_view')
            .select('*')
            .eq('user_id', user_id)
            .order('created_at', { ascending: false });

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch your reports',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};

export const getPublicReports = async (req, res, next) => {
    try {
        const { data, error } = await supabase
            .from('reports_view')
            .select('*');

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch public reports from view',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};

export const getReportById = async (req, res, next) => {
    const { id } = req.params;

    try {
        const { data: report, error: reportError } = await supabase
            .from('reports_view')
            .select('*, profiles(id, full_name, data_consent)')
            .eq('id', id)
            .single();

        if (reportError) {
            return res.status(404).json({
                message: 'Report not found',
                error: reportError.message
            });
        }

        // Fetch response logs (activity logs and agency responses)
        const { data: responseLogs, error: logsError } = await supabase
            .from('response_log')
            .select('*, profiles(full_name)')
            .eq('report_id', id)
            .order('created_at', { ascending: false });

        if (logsError) {
            console.error('Error fetching response logs:', logsError);
        }

        res.status(200).json({
            ...report,
            response_logs: responseLogs || []
        });
    } catch (error) {
        next(error);
    }
};

export const updateReportStatus = async (req, res, next) => {
    const { id } = req.params;
    const { status } = req.body;
    const user_id = req.user.id;

    try {
        // Get current status for audit log
        const { data: currentReport } = await supabase
            .from('reports')
            .select('status')
            .eq('id', id)
            .single();

        const { data, error } = await supabase
            .from('reports')
            .update({
                status,
                updated_at: new Date().toISOString()
            })
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to update report status',
                error: error.message
            });
        }

        // Log audit action
        await logAuditAction(id, user_id, 'status_update', 
            `Changed status from ${currentReport?.status || 'none'} to ${status}`);

        res.status(200).json({
            message: 'Report status updated successfully',
            report: data
        });
    } catch (error) {
        next(error);
    }
};

export const getReportsByClusterId = async (req, res, next) => {
    const { clusterId } = req.params;

    try {
        const { data, error } = await supabase
            .from('reports_view')
            .select('*')
            .eq('cluster_id', clusterId)
            .order('created_at', { ascending: false });

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch reports by cluster',
                error: error.message
            });
        }

        res.status(200).json(data);
    } catch (error) {
        next(error);
    }
};

export const batchCompleteReportsByCluster = async (req, res, next) => {
    const { clusterId } = req.params;

    try {
        const { data, error } = await supabase
            .from('reports')
            .update({
                status: 'resolved',
                updated_at: new Date().toISOString()
            })
            .eq('cluster_id', clusterId)
            .select();

        if (error) {
            return res.status(400).json({
                message: 'Failed to batch complete reports',
                error: error.message
            });
        }

        res.status(200).json({
            message: 'Reports batch completed successfully',
            updatedReports: data
        });
    } catch (error) {
        next(error);
    }
};

// Helper function to log audit action
const logAuditAction = async (reportId, userId, actionType, actionDetails) => {
    try {
        console.log('Logging audit action:', { reportId, userId, actionType, actionDetails });
        const { data, error } = await supabase
            .from('response_log')
            .insert({
                report_id: reportId,
                user_id: userId,
                action_type: actionType,
                action_details: actionDetails
            })
            .select()
            .single();

        if (error) {
            console.error('Failed to log audit action:', error);
        } else {
            console.log('Audit action logged successfully:', data);
        }
    } catch (error) {
        console.error('Failed to log audit action:', error);
        // Don't throw error - logging is secondary to main operation
    }
};

// Helper function to create notification
const createNotification = async (userId, reportId, title, body) => {
    try {
        console.log('Creating notification:', { userId, reportId, title, body });
        const { data, error } = await supabase
            .from('notifications')
            .insert({
                user_id: userId,
                report_id: reportId,
                title,
                body,
                is_read: false
            })
            .select()
            .single();

        if (error) {
            console.error('Failed to create notification:', error);
        } else {
            console.log('Notification created successfully:', data);
        }
    } catch (error) {
        console.error('Failed to create notification:', error);
        // Don't throw error - notification is secondary to main operation
    }
};

// Update lifecycle stage
export const updateLifecycleStage = async (req, res, next) => {
    const { id } = req.params;
    const { stage } = req.body;
    const user_id = req.user.id;

    try {
        // Get current stage for audit log and notification
        const { data: currentReport } = await supabase
            .from('reports')
            .select('stage, user_id, status')
            .eq('id', id)
            .single();

        // Determine status based on lifecycle stage
        let status = currentReport?.status || 'unresolved';
        if (stage === 'acknowledged' || stage === 'responded') {
            status = 'in_progress';
        } else if (stage === 'resolved') {
            status = 'waiting_for_feedback';
        }

        const { data, error } = await supabase
            .from('reports')
            .update({
                stage: stage,
                status: status,
                updated_at: new Date().toISOString()
            })
            .eq('id', id)
            .select()
            .single();

        if (error) {
            console.error('Supabase error updating lifecycle stage:', error);
            return res.status(400).json({
                message: 'Failed to update lifecycle stage',
                error: error.message
            });
        }

        // Log audit action
        await logAuditAction(id, user_id, 'lifecycle_stage_update',
            `Changed stage from ${currentReport?.stage || 'none'} to ${stage}`);

        // Create notification for the report owner
        if (currentReport?.user_id) {
            await createNotification(
                currentReport.user_id,
                id,
                'Lifecycle Stage Updated',
                `Your report lifecycle stage has been updated to ${stage}`
            );
        }

        res.status(200).json({
            message: 'Lifecycle stage updated successfully',
            report: data
        });
    } catch (error) {
        console.error('Error updating lifecycle stage:', error);
        next(error);
    }
};

// Acknowledge complaint (sets stage to 'acknowledged')
export const acknowledgeComplaint = async (req, res, next) => {
    const { id } = req.params;
    const user_id = req.user.id;

    try {
        const { data, error } = await supabase
            .from('reports')
            .update({ 
                stage: 'acknowledged',
                updated_at: new Date().toISOString()
            })
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to acknowledge complaint',
                error: error.message
            });
        }

        // Log audit action
        await logAuditAction(id, user_id, 'acknowledge_complaint', 
            'Complaint acknowledged by LGU');

        res.status(200).json({
            message: 'Complaint acknowledged successfully',
            report: data
        });
    } catch (error) {
        next(error);
    }
};

// Log agency response action (manual note from LGU)
export const logAgencyResponse = async (req, res, next) => {
    const { id } = req.params;
    const { action } = req.body;
    const user_id = req.user.id;

    try {
        const { data, error } = await supabase
            .from('response_log')
            .insert({
                report_id: id,
                user_id,
                action_type: 'manual_note',
                action_details: action
            })
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to log agency response',
                error: error.message
            });
        }

        res.status(201).json({
            message: 'Agency response logged successfully',
            response: data
        });
    } catch (error) {
        next(error);
    }
};

// Fetch agency responses for a report
export const fetchAgencyResponses = async (req, res, next) => {
    const { id } = req.params;

    try {
        const { data, error } = await supabase
            .from('response_log')
            .select('*')
            .eq('report_id', id)
            .order('created_at', { ascending: false });

        if (error) {
            console.error('Supabase error fetching agency responses:', error);
            return res.status(400).json({
                message: 'Failed to fetch agency responses',
                error: error.message
            });
        }

        res.status(200).json(data || []);
    } catch (error) {
        console.error('Error fetching agency responses:', error);
        next(error);
    }
};

export const updatePropertyOwnerConsent = async (req, res, next) => {
    const { id } = req.params;
    const { consent_status } = req.body;

    try {
        const updateData = {
            property_owner_consent_status: consent_status,
            updated_at: new Date().toISOString()
        };

        if (consent_status === 'obtained') {
            updateData.status = 'unresolved';
        }

        const { data, error } = await supabase
            .from('reports')
            .update(updateData)
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to update property owner consent status',
                error: error.message
            });
        }

        res.status(200).json({
            message: 'Property owner consent status updated successfully',
            report: data
        });
    } catch (error) {
        next(error);
    }
};

// LGU resolves the issue (sets status to waiting_for_feedback and lgu_resolved_at)
export const lguResolveReport = async (req, res, next) => {
    const { id } = req.params;
    const user_id = req.user.id;

    try {
        const { data: currentReport } = await supabase
            .from('reports')
            .select('user_id')
            .eq('id', id)
            .single();

        const { data, error } = await supabase
            .from('reports')
            .update({
                status: 'waiting_for_feedback',
                lgu_resolved_at: new Date().toISOString(),
                updated_at: new Date().toISOString()
            })
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to resolve report',
                error: error.message
            });
        }

        // Log audit action
        await logAuditAction(id, user_id, 'lgu_resolve', 'LGU marked report as resolved');

        // Send notification to reporter
        if (currentReport?.user_id) {
            await createNotification(
                currentReport.user_id,
                id,
                'Report Resolved',
                'The LGU has resolved your report! Please provide feedback.'
            );
        }

        res.status(200).json({
            message: 'Report resolved successfully',
            report: data
        });
    } catch (error) {
        next(error);
    }
};

// Citizen closes the report with satisfaction rating
export const citizenCloseReport = async (req, res, next) => {
    const { id } = req.params;
    const { satisfaction_rating } = req.body;
    const user_id = req.user.id;

    try {
        const { data: currentReport } = await supabase
            .from('reports')
            .select('user_id')
            .eq('id', id)
            .single();

        // Verify that the current user is the report owner
        if (currentReport?.user_id !== user_id) {
            return res.status(403).json({
                message: 'You are not authorized to close this report'
            });
        }

        const { data, error } = await supabase
            .from('reports')
            .update({
                status: 'closed',
                satisfaction_rating,
                citizen_closed_at: new Date().toISOString(),
                updated_at: new Date().toISOString()
            })
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to close report',
                error: error.message
            });
        }

        // Log audit action
        await logAuditAction(id, user_id, 'citizen_close', `Citizen closed report with satisfaction rating: ${satisfaction_rating}`);

        res.status(200).json({
            message: 'Report closed successfully',
            report: data
        });
    } catch (error) {
        next(error);
    }
};

// Get satisfaction ratings analytics
export const getSatisfactionAnalytics = async (req, res, next) => {
    try {
        // Get all closed reports with satisfaction ratings
        const { data, error } = await supabase
            .from('reports')
            .select('satisfaction_rating')
            .not('satisfaction_rating', 'is', null);

        if (error) {
            return res.status(400).json({
                message: 'Failed to fetch satisfaction ratings',
                error: error.message
            });
        }

        // Calculate distribution
        const distribution = {
            1: 0,
            2: 0,
            3: 0,
            4: 0,
            5: 0
        };

        let total = 0;
        let sum = 0;

        data.forEach(report => {
            const rating = report.satisfaction_rating;
            if (rating >= 1 && rating <= 5) {
                distribution[rating]++;
                total++;
                sum += rating;
            }
        });

        const average = total > 0 ? sum / total : 0;

        res.status(200).json({
            total,
            average: parseFloat(average.toFixed(2)),
            distribution
        });
    } catch (error) {
        next(error);
    }
};
