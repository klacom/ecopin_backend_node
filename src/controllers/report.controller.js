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
        // Validate image format if present
        if (image) {
            const fileExt = image.originalname.split('.').pop()?.toLowerCase();
            if (!fileExt || !VALID_IMAGE_EXTENSIONS.includes(fileExt)) {
                return res.status(400).json({
                    message: 'Invalid file extension. Only JPEG, JPG, PNG, and WEBP are allowed.'
                });
            }
        }

        // Set initial validation status to pending AI validation
        const validationStatus = VALIDATION_STATUS.PENDING_AI_VALIDATION;

        // PostGIS point format: 'POINT(longitude latitude)'
        const point = `POINT(${longitude} ${latitude})`;

        // Determine property owner consent status
        const propertyOwnerConsentStatus = onPrivateProperty ? 'pending' : 'not_required';

        const { data: report, error } = await supabase
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

        // Send response to user immediately
        res.status(201).json({
            message: 'Report submitted successfully! AI validation is in progress.',
            report: report
        });

        // Send pending validation notification
        createNotification(
            user_id,
            report.id,
            'pending_validation',
            'Report Submitted',
            'Your report is currently undergoing AI validation.'
        ).catch(err => console.error('Failed to send pending validation notification:', err));

        // Trigger background tasks without waiting
        (async () => {
            try {
                // Run AI validation in background if image is present
                if (image) {
                    const validation = await validateImage(image.buffer);
                    
                    // Handle severe violations
                    if (validation.severeViolation) {
                        console.log(`[SevereViolation] Detected in report ${report.id}: ${validation.severeCategories.join(', ')}`);
                        
                        // Get system settings for severe violation handling
                        const { data: settings } = await supabase
                            .from('system_settings')
                            .select('*')
                            .single();
                        
                        // Update report with severe violation flags
                        const severeCategory = validation.severeCategories[0] || 'other';
                        await supabase
                            .from('reports')
                            .update({
                                validation_status: VALIDATION_STATUS.REJECTED,
                                flagged_severe: true,
                                severe_violation_category: severeCategory,
                                rejection_reason: `Severe content violation detected: ${severeCategory}`,
                                updated_at: new Date().toISOString()
                            })
                            .eq('id', report.id);
                        
                        // Add to manual review queue
                        const { data: reviewItem } = await supabase
                            .from('manual_review_queue')
                            .insert({
                                report_id: report.id,
                                review_type: 'severe_violation',
                                priority: 'urgent',
                                status: 'pending'
                            })
                            .select()
                            .single();
                        
                        // Link report to review queue
                        await supabase
                            .from('reports')
                            .update({
                                manual_review_id: reviewItem.id
                            })
                            .eq('id', report.id);
                        
                        // Issue immediate strike if configured
                        if (settings && settings.severe_violation_immediate_strike) {
                            const suspensionDuration = settings.severe_violation_action === 'suspend_7d' 
                                ? settings.severe_violation_duration_hours || 168
                                : settings.severe_violation_action === 'suspend_24h'
                                    ? settings.severe_violation_duration_hours || 24
                                    : settings.severe_violation_action === 'permanent_ban'
                                        ? -1
                                        : null;
                            
                            // Create strike
                            const { data: strike } = await supabase
                                .from('strikes')
                                .insert({
                                    user_id,
                                    reason: `Severe content violation: ${severeCategory}`,
                                    violation_type: 'severe_content',
                                    issued_by: user_id, // System-issued
                                    severity: 'severe',
                                    severe_category: severeCategory,
                                    requires_manual_review: true,
                                    manual_review_status: 'pending',
                                    is_active: true
                                })
                                .select()
                                .single();
                            
                            // Link strike to review queue
                            await supabase
                                .from('manual_review_queue')
                                .update({
                                    strike_id: strike.id
                                })
                                .eq('id', reviewItem.id);
                            
                            // Apply suspension
                            if (suspensionDuration !== null) {
                                let suspendedUntil = null;
                                if (suspensionDuration === -1) {
                                    suspendedUntil = new Date('2099-12-31').toISOString();
                                } else {
                                    const now = new Date();
                                    suspendedUntil = new Date(now.getTime() + suspensionDuration * 60 * 60 * 1000).toISOString();
                                }
                                
                                await supabase
                                    .from('profiles')
                                    .update({
                                        suspended_until: suspendedUntil,
                                        strike_count: 1,
                                        last_strike_at: new Date().toISOString(),
                                        updated_at: new Date().toISOString()
                                    })
                                    .eq('id', user_id);
                            }
                        }
                    } else {
                        // Normal validation flow
                        await supabase
                            .from('reports')
                            .update({
                                validation_status: validation.status,
                                updated_at: new Date().toISOString()
                            })
                            .eq('id', report.id);

                        // Send notification based on validation result
                        if (validation.status === VALIDATION_STATUS.APPROVED) {
                            createNotification(
                                user_id,
                                report.id,
                                'approved',
                                'Report Approved',
                                'Your report has been approved.'
                            ).catch(err => console.error('Failed to send approval notification:', err));
                        } else if (validation.status === VALIDATION_STATUS.REJECTED) {
                            createNotification(
                                user_id,
                                report.id,
                                'rejected',
                                'Report Rejected',
                                'Your report violated our image policy.'
                            ).catch(err => console.error('Failed to send rejection notification:', err));
                        } else if (validation.status === VALIDATION_STATUS.MANUAL_REVIEW) {
                            createNotification(
                                user_id,
                                report.id,
                                'manual_review',
                                'Report Under Review',
                                'Your report has been flagged for manual review.'
                            ).catch(err => console.error('Failed to send manual review notification:', err));
                        }
                    }
                }
                // Trigger clustering
                await clusterReports();
            } catch (err) {
                console.error('Error in background tasks:', err);
            }
        })();
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

        // Filter out rejected reports and reports with denied consent
        const filteredData = (data || []).filter(report =>
            report.validation_status !== 'rejected' &&
            !(report.on_private_property && report.property_owner_consent_status === 'denied')
        );

        res.status(200).json(filteredData);
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

        res.status(200).json({
            message: 'Report status updated successfully',
            report: data
        });
    } catch (error) {
        next(error);
    }
};

export const updateReportValidation = async (req, res, next) => {
    const { id } = req.params;
    const { validation_status, rejection_reason } = req.body;
    const user_id = req.user.id;

    try {
        // Get current validation status for audit log
        const { data: currentReport } = await supabase
            .from('reports')
            .select('validation_status, user_id')
            .eq('id', id)
            .single();

        const updateData = {
            validation_status,
            updated_at: new Date().toISOString()
        };

        // Set rejection reason and timestamp if rejecting
        if (validation_status === 'rejected') {
            updateData.rejection_reason = rejection_reason || null;
            updateData.rejected_at = new Date().toISOString();
        } else {
            // Clear rejection fields if not rejected
            updateData.rejection_reason = null;
            updateData.rejected_at = null;
        }

        const { data, error } = await supabase
            .from('reports')
            .update(updateData)
            .eq('id', id)
            .select()
            .single();

        if (error) {
            return res.status(400).json({
                message: 'Failed to update report validation status',
                error: error.message
            });
        }

        // Create notification for the report owner if rejected
        if (validation_status === 'rejected' && currentReport?.user_id) {
            await createNotification(
                currentReport.user_id,
                id,
                'rejected',
                'Report Rejected',
                rejection_reason
                    ? `Your report has been rejected: ${rejection_reason}`
                    : 'Your report has been rejected.'
            );
        }

        res.status(200).json({
            message: 'Report validation status updated successfully',
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

        // Filter out rejected and denied reports
        const filteredData = (data || []).filter(report =>
            report.validation_status !== 'rejected' &&
            !(report.on_private_property && report.property_owner_consent_status === 'denied')
        );

        res.status(200).json(filteredData);
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
const createNotification = async (userId, reportId, type, title, body) => {
    try {
        console.log('Creating notification:', { userId, reportId, type, title, body });
        const { data, error } = await supabase
            .from('notifications')
            .insert({
                user_id: userId,
                report_id: reportId,
                type,
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

        // Update data - include validation_status when acknowledging
        const updateData = {
            stage: stage,
            status: status,
            updated_at: new Date().toISOString()
        };

        // Auto-approve when acknowledging
        if (stage === 'acknowledged') {
            updateData.validation_status = VALIDATION_STATUS.APPROVED;
        }

        const { data, error } = await supabase
            .from('reports')
            .update(updateData)
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
            `Changed stage from ${currentReport?.stage || 'none'} to ${stage}${stage === 'acknowledged' ? ' and approved' : ''}`);

        // Create notification for the report owner
        if (currentReport?.user_id) {
            await createNotification(
                currentReport.user_id,
                id,
                'lifecycle_update',
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

// Acknowledge complaint (sets stage to 'acknowledged' and validation_status to 'approved')
export const acknowledgeComplaint = async (req, res, next) => {
    const { id } = req.params;
    const user_id = req.user.id;

    try {
        const { data, error } = await supabase
            .from('reports')
            .update({
                stage: 'acknowledged',
                validation_status: 'approved',
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
            'Complaint acknowledged by LGU and approved');

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
                'resolved',
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

// Create new report from rejected report (copies title, description, location only)
export const createReportFromRejected = async (req, res, next) => {
    const { id } = req.params;
    const user_id = req.user.id;

    try {
        // Fetch the rejected report
        const { data: originalReport, error: fetchError } = await supabase
            .from('reports')
            .select('*')
            .eq('id', id)
            .single();

        if (fetchError) {
            return res.status(404).json({
                message: 'Report not found',
                error: fetchError.message
            });
        }

        // Verify the report belongs to the current user
        if (originalReport.user_id !== user_id) {
            return res.status(403).json({
                message: 'You can only create new reports from your own rejected reports'
            });
        }

        // Verify the report is rejected
        if (originalReport.validation_status !== 'rejected') {
            return res.status(400).json({
                message: 'You can only create new reports from rejected reports'
            });
        }

        // Parse location from PostGIS point format
        let latitude = null;
        let longitude = null;
        if (originalReport.location) {
            try {
                // Handle PostGIS point format: 'POINT(longitude latitude)'
                const match = originalReport.location.match(/POINT\s*\(([^]+)\s+([^]+)\)/i);
                if (match) {
                    longitude = parseFloat(match[1]);
                    latitude = parseFloat(match[2]);
                }
            } catch (error) {
                console.error('Error parsing location:', error);
            }
        }

        // Create new report with copied data
        const { data: newReport, error: createError } = await supabase
            .from('reports')
            .insert({
                user_id,
                title: originalReport.title,
                description: originalReport.description,
                issue_type: originalReport.issue_type,
                location: originalReport.location,
                on_private_property: originalReport.on_private_property,
                property_owner_consent_status: originalReport.on_private_property ? 'pending' : 'not_required',
                status: originalReport.on_private_property ? 'pending_owner_consent' : 'unresolved',
                validation_status: VALIDATION_STATUS.PENDING
            })
            .select()
            .single();

        if (createError) {
            return res.status(400).json({
                message: 'Failed to create new report',
                error: createError.message
            });
        }

        res.status(201).json({
            message: 'New report created successfully from rejected report',
            report: newReport
        });
    } catch (error) {
        next(error);
    }
};
