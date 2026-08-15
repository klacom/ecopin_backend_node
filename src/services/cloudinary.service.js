import cloudinary from '../config/cloudinary.config.js';

export const uploadFromBuffer = (buffer, folder, publicId) => {
  return new Promise((resolve, reject) => {
    const uploadStream = cloudinary.uploader.upload_stream({ folder, public_id: publicId, resource_type: 'image' }, (error, result) => {
      if (error) reject(error); else resolve(result);
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
