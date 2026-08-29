import cloudinary from '../config/cloudinary.config.js';

export const uploadFromBuffer = (buffer, folder, publicId) => {
  return new Promise((resolve, reject) => {
    const uploadStream = cloudinary.uploader.upload_stream(
      { 
        folder, 
        public_id: publicId, 
        resource_type: 'image',
        timeout: 120000 // 2 minute timeout
      }, 
      (error, result) => {
        if (error) {
          console.error('[Cloudinary] Image upload failed:', error);
          reject(new Error(`Cloudinary image upload failed: ${error.message || error}`));
        } else {
          console.log('[Cloudinary] Image upload successful:', result.public_id);
          resolve(result);
        }
      }
    );
    uploadStream.on('error', (error) => {
      console.error('[Cloudinary] Stream error:', error);
      reject(new Error(`Cloudinary stream error: ${error.message}`));
    });
    uploadStream.end(buffer);
  });
};

export const uploadVideoFromBuffer = (buffer, folder, publicId) => {
  return new Promise((resolve, reject) => {
    const uploadStream = cloudinary.uploader.upload_stream(
      { 
        folder, 
        public_id: publicId, 
        resource_type: 'video',
        timeout: 300000 // 5 minute timeout for videos
      }, 
      (error, result) => {
        if (error) {
          console.error('[Cloudinary] Video upload failed:', error);
          reject(new Error(`Cloudinary video upload failed: ${error.message || error}`));
        } else {
          console.log('[Cloudinary] Video upload successful:', result.public_id);
          resolve(result);
        }
      }
    );
    uploadStream.on('error', (error) => {
      console.error('[Cloudinary] Stream error:', error);
      reject(new Error(`Cloudinary stream error: ${error.message}`));
    });
    uploadStream.end(buffer);
  });
};

export const deleteFromCloudinary = async (url) => {
  const parts = url.split('/');
  const filename = parts[parts.length - 1];
  const publicId = filename.split('.')[0];
  return await cloudinary.uploader.destroy(publicId, { resource_type: 'image' });
};

export const deleteVideoFromCloudinary = async (url) => {
  const parts = url.split('/');
  const filename = parts[parts.length - 1];
  const publicId = filename.split('.')[0];
  return await cloudinary.uploader.destroy(publicId, { resource_type: 'video' });
};
