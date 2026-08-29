import { supabaseAdmin as supabase } from "../config/supabase.config.js";
import multer from 'multer';
import exifParser from 'exif-parser';
import cloudinary from '../config/cloudinary.config.js';
import { classifyImage, mapClassifierToValidation } from '../services/classifierClient.service.js';
import { extractVideoFrames } from '../services/videoFrameExtractor.service.js';
import { classifyVideoFrames } from '../services/videoFrameClassifier.service.js';
import { aggregateVideoValidation } from '../services/videoFrameAggregator.service.js';
import { VALIDATION_STATUS, VALID_IMAGE_MIME_TYPES, VALID_IMAGE_EXTENSIONS, VALID_VIDEO_MIME_TYPES, VALID_VIDEO_EXTENSIONS, EVIDENCE_PHOTO_FILE_SIZE, REPORT_VIDEO_FILE_SIZE, REPORT_PHOTOS_STORAGE_PATH, BEFORE_AFTER_PHOTO_FILE_SIZE } from '../config/index.js';
import { clusterReports } from '../modules/clustering/index.js';
import { uploadFromBuffer, deleteFromCloudinary, uploadVideoFromBuffer } from '../services/cloudinary.service.js';

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

// Configure multer for accepting either image or video (for report creation and evidence)
const mediaStorage = multer.memoryStorage();
export const mediaUpload = multer({
    storage: mediaStorage,
    limits: { fileSize: Math.max(EVIDENCE_PHOTO_FILE_SIZE, REPORT_VIDEO_FILE_SIZE) },
    fileFilter: (req, file, cb) => {
        const isImage = VALID_IMAGE_MIME_TYPES.includes(file.mimetype);
        const isVideo = VALID_VIDEO_MIME_TYPES.includes(file.mimetype);
        
        if (isImage || isVideo) {
            cb(null, true);
        } else {
            cb(new Error('Invalid file type. Only JPEG, JPG, PNG, WEBP, MP4, MOV, and WEBM are allowed.'), false);
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

        // Upload to Cloudinary
        const folder = `report_photos/${id}/${photo_type}`;
        const publicId = `${Date.now()}_${req.file.originalname.replace(/\.[^/.]+$/, '')}`;
        let uploadResult;
        try {
          uploadResult = await uploadFromBuffer(req.file.buffer, folder, publicId);
        } catch (uploadError) {
          console.error('Cloudinary upload error:', uploadError);
          return res.status(400).json({
            message: 'Failed to upload photo',
            error: uploadError.message
          });
        }
        const secureUrl = uploadResult.secure_url;
        console.log('Upload successful:', uploadResult);

        // Get public URL (already provided by Cloudinary)
        const urlData = { publicUrl: secureUrl };

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

        // Delete from Cloudinary
        try {
            await deleteFromCloudinary(photoUrl);
        } catch (deleteError) {
            console.error('Cloudinary delete error:', deleteError);
            return res.status(400).json({
                message: 'Failed to delete photo from storage',
                error: deleteError.message
            });
        }

        console.log('Photo deleted from Cloudinary successfully');

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
    console.log('Files received:', req.files);

    // Check for media files (image or video)
    const imageFile = req.files && req.files['image'] ? req.files['image'][0] : null;
    const videoFile = req.files && req.files['video'] ? req.files['video'][0] : null;

    // Validate that only one media type is provided
    if (imageFile && videoFile) {
        return res.status(400).json({ 
            message: 'Please provide either an image or a video, not both.' 
        });
    }

    if (!imageFile && !videoFile) {
        return res.status(400).json({ message: 'No file uploaded' });
    }

    const mediaFile = imageFile || videoFile;
    const mediaType = imageFile ? 'image' : 'video';

    console.log('Media type:', mediaType);
    console.log('File received:', mediaFile.originalname);

    // Validate file extension based on media type
    const fileExt = mediaFile.originalname.split('.').pop()?.toLowerCase();
    if (mediaType === 'image') {
        if (!fileExt || !VALID_IMAGE_EXTENSIONS.includes(fileExt)) {
            return res.status(400).json({
                message: 'Invalid file extension. Only JPEG, JPG, PNG, and WEBP are allowed.'
            });
        }
    } else {
        if (!fileExt || !VALID_VIDEO_EXTENSIONS.includes(fileExt)) {
            return res.status(400).json({
                message: 'Invalid file extension. Only MP4, MOV, and WEBM are allowed.'
            });
        }
    }

    // For videos, upload to Cloudinary
    if (mediaType === 'video') {
        try {
            const timestamp = Date.now();
            const filename = `${timestamp}_${mediaFile.originalname.replace(/\.[^/.]+$/, '')}`;
            const videoUploadResult = await uploadVideoFromBuffer(
                mediaFile.buffer,
                `report_evidence/${reportId}`,
                filename
            );
            console.log('Video uploaded to Cloudinary:', videoUploadResult.secure_url);
            
            return res.status(201).json({
                message: 'Video evidence uploaded successfully',
                evidence: {
                    url: videoUploadResult.secure_url,
                    public_id: videoUploadResult.public_id,
                    type: 'video',
                    filename: mediaFile.originalname,
                    mimetype: mediaFile.mimetype,
                    size: mediaFile.size
                }
            });
        } catch (videoError) {
            console.error('Cloudinary video upload error:', videoError);
            return res.status(400).json({
                message: 'Failed to upload video',
                error: videoError.message
            });
        }
    }

    // For images, proceed with existing upload logic
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
            const parser = exifParser.create(mediaFile.buffer);
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
        const filename = `${timestamp}_${mediaFile.originalname}`;
        const filePath = `${reportId}/${filename}`;

        console.log('Uploading evidence to Cloudinary, folder:', `report_evidence/${reportId}`);
        console.log('File path:', filePath);

        // Upload to Cloudinary
        const folder = `report_evidence/${reportId}`;
        const publicId = `${timestamp}_${mediaFile.originalname.replace(/\.[^/.]+$/, '')}`;
        let uploadResult;
        try {
            uploadResult = await uploadFromBuffer(mediaFile.buffer, folder, publicId);
        } catch (uploadError) {
            console.error('Cloudinary upload error:', uploadError);
            return res.status(400).json({
                message: 'Failed to upload image',
                error: uploadError.message
            });
        }

        const secureUrl = uploadResult.secure_url;
        console.log('Upload successful, URL:', secureUrl);

        res.status(201).json({
            message: 'Evidence uploaded successfully',
            evidence: {
                url: secureUrl,
                path: filePath,
                public_id: uploadResult.public_id,
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
        const prefix = `report_evidence/${reportId}`;

        // Fetch both image and video resources
        const [imageResources, videoResources] = await Promise.all([
            cloudinary.api.resources({
                type: 'upload',
                prefix: prefix,
                max_results: 100,
                resource_type: 'image'
            }),
            cloudinary.api.resources({
                type: 'upload',
                prefix: prefix,
                max_results: 100,
                resource_type: 'video'
            })
        ]);

        const allResources = [...(imageResources.resources || []), ...(videoResources.resources || [])];

        const evidence = allResources.map(resource => {
            const fullPublicId = resource.public_id; // e.g. report_evidence/123/169_abc
            const parts = fullPublicId.split('/');
            const fileName = parts[parts.length - 1] +
                (resource.format ? '.' + resource.format : '');
            return {
                name: fileName,
                url: resource.secure_url,
                size: resource.bytes,
                public_id: resource.public_id,
                createdAt: resource.created_at,
                resource_type: resource.resource_type // 'image' or 'video'
            };
        });

        console.log('Returning evidence count:', evidence.length);
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
        latitude,
        longitude,
        on_private_property
    } = req.body;
    const user_id = req.user.id;
    
    // Check for media files (image or video)
    const imageFiles = req.files && req.files['image'] ? req.files['image'] : [];
    const videoFile = req.files && req.files['video'] ? req.files['video'][0] : null;

    // Require at least one media type
    if (imageFiles.length === 0 && !videoFile) {
        return res.status(400).json({ 
            message: 'Please provide either an image or a video.' 
        });
    }

    const mediaFile = imageFiles.length > 0 ? imageFiles[0] : videoFile;
    const mediaType = imageFiles.length > 0 ? 'image' : 'video';

    const onPrivateProperty =
        req.body.on_private_property === true ||
        req.body.on_private_property === "true";

    try {
        // Validate file formats
        for (const imageFile of imageFiles) {
            const fileExt = imageFile.originalname.split('.').pop()?.toLowerCase();
            if (!fileExt || !VALID_IMAGE_EXTENSIONS.includes(fileExt)) {
                return res.status(400).json({
                    message: 'Invalid file extension. Only JPEG, JPG, PNG, and WEBP are allowed.'
                });
            }
        }
        
        if (videoFile) {
            const fileExt = videoFile.originalname.split('.').pop()?.toLowerCase();
            if (!fileExt || !VALID_VIDEO_EXTENSIONS.includes(fileExt)) {
                return res.status(400).json({
                    message: 'Invalid file extension. Only MP4, MOV, and WEBM are allowed.'
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
                issue_type: 'pending', // Will be updated by AI validation
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
                let finalValidationStatus = VALIDATION_STATUS.MANUAL_REVIEW;
                let finalRejectionReason = null;
                let finalIssueType = null;

                // Upload media to Cloudinary FIRST (independent of AI validation)
                console.log(`[Evidence] Starting media upload for report ${report.id}`);
                
                // Upload video to Cloudinary if present
                if (videoFile) {
                    try {
                        console.log(`[Video] Uploading video for report ${report.id}`);
                        const timestamp = Date.now();
                        const videoUploadResult = await uploadVideoFromBuffer(
                            videoFile.buffer, 
                            `report_evidence/${report.id}`, 
                            `${timestamp}_${report.id}_video`
                        );
                        console.log(`[Video] Uploaded video to Cloudinary: ${videoUploadResult.secure_url}`);
                    } catch (videoUploadError) {
                        console.error(`[Video] Upload failed for report ${report.id}:`, videoUploadError);
                        // Continue with validation even if upload fails
                        createNotification(
                            user_id,
                            report.id,
                            'error',
                            'Evidence Upload Failed',
                            'Your video evidence could not be uploaded. Please try uploading it again.'
                        ).catch(err => console.error('Failed to send upload error notification:', err));
                    }
                }

                // Upload all images to Cloudinary if present
                for (const imageFile of imageFiles) {
                    try {
                        console.log(`[Image] Uploading image for report ${report.id}`);
                        const timestamp = Date.now();
                        const filename = `${timestamp}_${imageFile.originalname.replace(/\.[^/.]+$/, '')}`;
                        const imageUploadResult = await uploadFromBuffer(
                            imageFile.buffer,
                            `report_evidence/${report.id}`,
                            filename
                        );
                        console.log(`[Image] Uploaded image to Cloudinary: ${imageUploadResult.secure_url}`);
                    } catch (imageUploadError) {
                        console.error(`[Image] Upload failed for report ${report.id}:`, imageUploadError);
                        // Continue with validation even if upload fails
                        createNotification(
                            user_id,
                            report.id,
                            'error',
                            'Evidence Upload Failed',
                            'Your image evidence could not be uploaded. Please try uploading it again.'
                        ).catch(err => console.error('Failed to send upload error notification:', err));
                    }
                }

                console.log(`[Evidence] Media upload completed for report ${report.id}`);

                // Process video for AI validation if present
                if (videoFile) {
                    console.log(`[VIDEO-PIPELINE] START report=${report.id}, filename=${videoFile.originalname}, size=${videoFile.size}, mime=${videoFile.mimetype}`);
                    
                    try {
                        console.log(`[VIDEO-PIPELINE] Stage: EXTRACTION - report=${report.id}`);
                        
                        // Extract 5 frames
                        const frames = await extractVideoFrames(videoFile.buffer, videoFile.originalname);
                        console.log(`[VIDEO-PIPELINE] Stage: EXTRACTION COMPLETE - report=${report.id}, frames=${frames.length}`);
                        
                        console.log(`[VIDEO-PIPELINE] Stage: CLASSIFICATION - report=${report.id}`);
                        
                        // Classify frames in parallel
                        const frameResults = await classifyVideoFrames(frames);
                        console.log(`[VIDEO-PIPELINE] Stage: CLASSIFICATION COMPLETE - report=${report.id}, results=${frameResults.length}`);
                        
                        console.log(`[VIDEO-PIPELINE] Stage: AGGREGATION - report=${report.id}`);
                        
                        // Aggregate results
                        const aggregated = aggregateVideoValidation(frameResults);
                        console.log(`[VIDEO-PIPELINE] Stage: AGGREGATION COMPLETE - report=${report.id}, status=${aggregated.validation_status}, dominant=${aggregated.dominant_class}`);
                        
                        // Use video validation as primary if no image, or for combined reports
                        if (imageFiles.length === 0) {
                            finalValidationStatus = aggregated.validation_status;
                            finalRejectionReason = aggregated.rejection_reason;
                            if (aggregated.dominant_class) {
                                finalIssueType = aggregated.dominant_class;
                            }
                        }
                        
                        console.log(`[VIDEO-PIPELINE] COMPLETE report=${report.id}, status=${finalValidationStatus}`);
                    } catch (videoError) {
                        console.error(`[VIDEO-PIPELINE] FAILED report=${report.id}, stage=AI_PROCESSING, error=${videoError.message}`);
                        // If only video was provided, fall back to MANUAL_REVIEW
                        if (imageFiles.length === 0) {
                            finalValidationStatus = VALIDATION_STATUS.MANUAL_REVIEW;
                            finalRejectionReason = `Video processing failed: ${videoError.message}`;
                        }
                    }
                }

                // Run EfficientNet classifier on all images in background if images are present
                if (imageFiles.length > 0) {
                    console.log(`[Classifier] Processing ${imageFiles.length} images for report ${report.id}`);
                    
                    const imageResults = [];
                    for (const imageFile of imageFiles) {
                        try {
                            const classifierResult = await classifyImage(
                                imageFile.buffer,
                                imageFile.originalname,
                                imageFile.mimetype
                            );
                            if (classifierResult.ok) {
                                imageResults.push(classifierResult);
                                console.log(`[Classifier] Image ${imageFile.originalname} classified successfully`);
                            } else {
                                console.error(`[Classifier] Inference failed for ${imageFile.originalname}:`, classifierResult.error);
                            }
                        } catch (classifierErr) {
                            console.error(`[Classifier] Exception for ${imageFile.originalname}:`, classifierErr);
                        }
                    }

                    // Aggregate image results using simple majority rule
                    if (imageResults.length > 0) {
                        const statusCounts = {
                            approved: 0,
                            rejected: 0,
                            manual_review: 0
                        };

                        for (const result of imageResults) {
                            const mapped = mapClassifierToValidation(result);
                            if (mapped.status === VALIDATION_STATUS.APPROVED) statusCounts.approved++;
                            else if (mapped.status === VALIDATION_STATUS.REJECTED) statusCounts.rejected++;
                            else statusCounts.manual_review++;
                        }

                        console.log(`[Classifier] Image results: ${JSON.stringify(statusCounts)}`);

                        // Determine final status based on majority
                        if (statusCounts.rejected > statusCounts.approved && statusCounts.rejected > statusCounts.manual_review) {
                            finalValidationStatus = VALIDATION_STATUS.REJECTED;
                            finalRejectionReason = 'Majority of images were rejected.';
                        } else if (statusCounts.approved > statusCounts.rejected && statusCounts.approved > statusCounts.manual_review) {
                            finalValidationStatus = VALIDATION_STATUS.APPROVED;
                        } else {
                            finalValidationStatus = VALIDATION_STATUS.MANUAL_REVIEW;
                            finalRejectionReason = 'Mixed or unclear image validation results.';
                        }

                        // Use image validation as primary if no video, or for combined reports
                        if (!videoFile) {
                            finalValidationStatus = finalValidationStatus;
                            finalRejectionReason = finalRejectionReason;
                        }
                    } else {
                        // All classifications failed, fall back to manual review
                        finalValidationStatus = VALIDATION_STATUS.MANUAL_REVIEW;
                        finalRejectionReason = 'All image classifications failed.';
                    }
                }

                // Final database update with combined validation status
                console.log(`[DATABASE-UPDATE] START report=${report.id}, status=${finalValidationStatus}, issue_type=${finalIssueType}`);
                
                const updatePayload = {
                    validation_status: finalValidationStatus,
                    updated_at: new Date().toISOString(),
                };
                if (finalIssueType) {
                    updatePayload.issue_type = finalIssueType;
                }

                const { error: dbError } = await supabase
                    .from('reports')
                    .update(updatePayload)
                    .eq('id', report.id);
                
                if (dbError) {
                    console.error(`[DATABASE-UPDATE] FAILED report=${report.id}, error=${dbError.message}`);
                    throw new Error(`Database update failed: ${dbError.message}`);
                } else {
                    console.log(`[DATABASE-UPDATE] SUCCESS report=${report.id}`);
                }

                // Send notification based on final validation result
                if (finalValidationStatus === VALIDATION_STATUS.APPROVED) {
                    createNotification(
                        user_id,
                        report.id,
                        'approved',
                        'Report Approved',
                        'Your report has been approved.'
                    ).catch(err => console.error('Failed to send approval notification:', err));
                } else if (finalValidationStatus === VALIDATION_STATUS.REJECTED) {
                    createNotification(
                        user_id,
                        report.id,
                        'rejected',
                        'Report Rejected',
                        finalRejectionReason || 'Your report violated our policy.'
                    ).catch(err => console.error('Failed to send rejection notification:', err));
                } else if (finalValidationStatus === VALIDATION_STATUS.MANUAL_REVIEW) {
                    createNotification(
                        user_id,
                        report.id,
                        'manual_review',
                        'Report Under Review',
                        'Your report has been flagged for manual review.'
                    ).catch(err => console.error('Failed to send manual review notification:', err));
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
