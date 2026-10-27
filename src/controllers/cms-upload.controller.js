import { prepareCmsUpload, completeCmsUpload } from '../services/cms-upload.service.js';

export async function prepareCmsMedia(req, res, next) {
    try { res.status(200).json(await prepareCmsUpload(req.user.id, req.body)); }
    catch (error) { next(error); }
}

export async function completeCmsMedia(req, res, next) {
    try { res.status(200).json(await completeCmsUpload(req.user.id, req.body)); }
    catch (error) { next(error); }
}
