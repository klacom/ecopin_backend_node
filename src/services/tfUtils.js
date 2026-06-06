import * as tf from '@tensorflow/tfjs';
import sharp from 'sharp';

/**
 * Converts an image buffer to a 3D Tensor using Sharp.
 * This replaces tf.node.decodeImage to avoid native build issues on Windows.
 * 
 * @param {Buffer} imageBuffer - The raw image buffer.
 * @param {Object} options - Optional resize and processing options.
 * @returns {Promise<tf.Tensor3D>} - A 3D Tensor of the image.
 */
export const bufferToTensor = async (imageBuffer, options = {}) => {
    let pipeline = sharp(imageBuffer).removeAlpha();

    if (options.resize) {
        pipeline = pipeline.resize(options.resize.width, options.resize.height);
    }

    const { data, info } = await pipeline
        .raw()
        .toBuffer({ resolveWithObject: true });

    return tf.tensor3d(
        new Uint8Array(data),
        [info.height, info.width, info.channels],
        'int32'
    );
};
