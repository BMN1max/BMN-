'use strict';

const express = require('express');
const { S3Client, PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const { randomUUID } = require('crypto');
const { requireUser } = require('../supabase');

const router = express.Router();
const allowedTypes = new Set(['video/mp4', 'video/quicktime', 'video/webm']);
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const objectKeyPattern = new RegExp(`^uploads/${UUID}/${UUID}\\.(mp4|mov|webm)$`, 'i');

function getR2() {
  const required = ['R2_ACCOUNT_ID', 'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY', 'R2_BUCKET_NAME'];
  if (required.some((key) => !process.env[key])) {
    throw new Error('Cloudflare R2 credentials are not configured.');
  }
  const endpoint = process.env.R2_ENDPOINT || `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  return new S3Client({
    region: 'auto',
    endpoint,
    forcePathStyle: true,
    credentials: {
      accessKeyId: process.env.R2_ACCESS_KEY_ID,
      secretAccessKey: process.env.R2_SECRET_ACCESS_KEY,
    },
  });
}

function bucketName() {
  if (!process.env.R2_BUCKET_NAME) throw new Error('R2_BUCKET_NAME is not configured.');
  return process.env.R2_BUCKET_NAME;
}

function publicApiBase() {
  const value = String(process.env.PUBLIC_API_URL || '').trim().replace(/\/+$/, '');
  if (!value || !/^https:\/\//i.test(value)) {
    throw new Error('Set PUBLIC_API_URL to the HTTPS base URL of the deployed BMN Community API.');
  }
  return value;
}

// Authenticated upload ticket. The browser uploads directly to R2; the API never
// receives the video bytes. R2 remains private and its credentials stay server-side.
router.post('/presign-video', requireUser, async (req, res) => {
  try {
    const { filename, content_type, size_bytes } = req.body || {};
    const maxBytes = Number(process.env.MAX_VIDEO_BYTES || 209715200); // 200 MiB
    if (typeof filename !== 'string' || !filename.trim() || filename.length > 240) {
      return res.status(400).json({ error: 'A valid filename is required.' });
    }
    if (!allowedTypes.has(content_type)) {
      return res.status(415).json({ error: 'Supported video types: MP4, MOV/QuickTime, and WebM.' });
    }
    if (!Number.isSafeInteger(size_bytes) || size_bytes < 1 || size_bytes > maxBytes) {
      return res.status(413).json({ error: `Video must be between 1 byte and ${Math.round(maxBytes / 1048576)} MiB.` });
    }

    const ext = content_type === 'video/quicktime' ? 'mov' : content_type === 'video/webm' ? 'webm' : 'mp4';
    const key = `uploads/${req.user.id}/${randomUUID()}.${ext}`;
    const s3 = getR2();
    const command = new PutObjectCommand({
      Bucket: bucketName(),
      Key: key,
      ContentType: content_type,
      ContentLength: size_bytes,
      Metadata: { owner: req.user.id },
    });
    const upload_url = await getSignedUrl(s3, command, { expiresIn: 300 });
    const media_url = `${publicApiBase()}/api/media/play?key=${encodeURIComponent(key)}`;

    return res.status(200).json({
      upload_url,
      object_key: key,
      media_url,
      expires_in: 300,
      required_headers: { 'Content-Type': content_type },
      storage: 'cloudflare-r2',
    });
  } catch (error) {
    console.error('R2 presigned upload setup failed:', error.message);
    return res.status(503).json({ error: 'Secure R2 upload is not configured or is temporarily unavailable.' });
  }
});

// Public playback for published posts: the bucket stays private. This endpoint
// only signs tightly shaped, UUID-based keys and redirects to a short-lived R2 URL.
// The post's media_url acts as a bearer link; do not publish raw R2 credentials.
router.get('/play', async (req, res) => {
  try {
    const key = typeof req.query.key === 'string' ? req.query.key : '';
    if (!objectKeyPattern.test(key)) return res.status(400).json({ error: 'Invalid media key.' });
    const s3 = getR2();
    const playbackUrl = await getSignedUrl(
      s3,
      new GetObjectCommand({ Bucket: bucketName(), Key: key }),
      { expiresIn: 300 },
    );
    res.set('Cache-Control', 'private, no-store, max-age=0');
    res.set('Referrer-Policy', 'no-referrer');
    return res.redirect(302, playbackUrl);
  } catch (error) {
    console.error('R2 playback URL setup failed:', error.message);
    return res.status(503).json({ error: 'Video playback is temporarily unavailable.' });
  }
});

module.exports = router;
