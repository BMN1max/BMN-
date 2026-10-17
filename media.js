const express = require('express');
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const { randomUUID } = require('crypto');
const { requireUser } = require('../supabase');

const router = express.Router();
const allowedTypes = new Set(['video/mp4', 'video/quicktime', 'video/webm']);

function getS3() {
  const required = ['AWS_REGION', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_S3_BUCKET_NAME'];
  if (required.some(key => !process.env[key])) throw new Error('S3 upload service is not configured.');
  return new S3Client({ region: process.env.AWS_REGION, credentials: { accessKeyId: process.env.AWS_ACCESS_KEY_ID, secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY } });
}

router.post('/presign-video', requireUser, async (req, res) => {
  try {
    const { filename, content_type, size_bytes } = req.body || {};
    const maxBytes = Number(process.env.MAX_VIDEO_BYTES || 209715200);
    if (!filename || typeof filename !== 'string' || filename.length > 240) return res.status(400).json({ error: 'A valid filename is required.' });
    if (!allowedTypes.has(content_type)) return res.status(415).json({ error: 'Supported video types: MP4, MOV/QuickTime, and WebM.' });
    if (!Number.isSafeInteger(size_bytes) || size_bytes < 1 || size_bytes > maxBytes) return res.status(413).json({ error: `Video must be between 1 byte and ${Math.round(maxBytes / 1048576)} MB.` });
    const ext = content_type === 'video/quicktime' ? 'mov' : content_type === 'video/webm' ? 'webm' : 'mp4';
    const key = `uploads/${req.user.id}/${randomUUID()}.${ext}`;
    if (!process.env.CDN_DISTRIBUTION_DOMAIN) return res.status(503).json({ error: 'Configure a private-origin CDN domain before enabling video posts.' });
    const s3 = getS3();
    const command = new PutObjectCommand({ Bucket: process.env.AWS_S3_BUCKET_NAME, Key: key, ContentType: content_type, ContentLength: size_bytes, Metadata: { owner: req.user.id } });
    const upload_url = await getSignedUrl(s3, command, { expiresIn: 300 });
    const media_url = process.env.CDN_DISTRIBUTION_DOMAIN ? `https://${process.env.CDN_DISTRIBUTION_DOMAIN}/${key}` : null;
    return res.status(200).json({ upload_url, object_key: key, media_url, expires_in: 300, required_headers: { 'Content-Type': content_type } });
  } catch (error) {
    console.error('Presigned video upload setup failed:', error.message);
    return res.status(503).json({ error: 'Secure video upload is not configured or is temporarily unavailable.' });
  }
});

module.exports = router;
