'use strict';

const express = require('express');
const {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  HeadBucketCommand
} = require('@aws-sdk/client-s3');

const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const { randomUUID } = require('crypto');
const { requireUser } = require('../supabase');

const router = express.Router();

const allowedTypes = new Set([
  'video/mp4',
  'video/quicktime',
  'video/webm'
]);

// Browsers/devices report the same formats under different names.
const typeAliases = {
  'video/mov': 'video/quicktime',
  'video/x-quicktime': 'video/quicktime',
  'video/x-m4v': 'video/mp4'
};

const UUID =
  '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

const uuidPattern = new RegExp(`^${UUID}$`, 'i');

const objectKeyPattern = new RegExp(
  `^uploads/${UUID}/${UUID}\\.(mp4|mov|webm)$`,
  'i'
);

function intFromEnv(name, fallback, min, max) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(value)));
}

// Upload links must stay valid long enough for a large video on a slow phone connection.
const UPLOAD_URL_TTL = () => intFromEnv('UPLOAD_URL_TTL_SECONDS', 1800, 300, 3600);

// A playback link is minted on every /play request and the browser keeps using the
// redirected URL (including Range requests while seeking) for as long as the <video>
// element lives, so it must outlive a viewing session. SigV4 allows at most 7 days.
const PLAYBACK_URL_TTL = () => intFromEnv('PLAYBACK_URL_TTL_SECONDS', 21600, 300, 604800);

function getR2() {
  const required = [
    'R2_ACCOUNT_ID',
    'R2_ACCESS_KEY_ID',
    'R2_SECRET_ACCESS_KEY',
    'R2_BUCKET_NAME'
  ];

  const missing = required.filter((key) => !process.env[key]);
  if (missing.length) {
    // Names only. Values are never logged or returned.
    throw Object.assign(
      new Error(`Missing environment variables: ${missing.join(', ')}`),
      { configError: true }
    );
  }

  const endpoint =
    process.env.R2_ENDPOINT ||
    `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;

  return new S3Client({
    region: 'auto',
    endpoint,
    forcePathStyle: true,
    // AWS SDK v3 (>= 3.729) adds CRC32 checksum parameters to presigned PUT URLs by default.
    // R2 then rejects the browser's upload, which surfaces as a generic network/CORS error.
    // Only compute/validate checksums when an operation strictly requires them.
    requestChecksumCalculation: 'WHEN_REQUIRED',
    responseChecksumValidation: 'WHEN_REQUIRED',
    credentials: {
      accessKeyId: process.env.R2_ACCESS_KEY_ID,
      secretAccessKey: process.env.R2_SECRET_ACCESS_KEY
    }
  });
}

function bucketName() {
  if (!process.env.R2_BUCKET_NAME) {
    throw Object.assign(new Error('R2_BUCKET_NAME is not configured.'), {
      configError: true
    });
  }

  return process.env.R2_BUCKET_NAME;
}

function publicApiBase(req) {
  const configured = String(process.env.PUBLIC_API_URL || '')
    .trim()
    .replace(/\/+$/, '');

  if (configured) {
    if (!/^https:\/\//i.test(configured)) {
      throw Object.assign(
        new Error('PUBLIC_API_URL must start with https://'),
        { configError: true }
      );
    }
    return configured;
  }

  // Fallback so a missing variable does not block uploads. Render terminates TLS at its
  // proxy; `trust proxy` is enabled in server.js so req.protocol reflects the public scheme.
  const host = req.get('host');
  if (!host) {
    throw Object.assign(
      new Error('Set PUBLIC_API_URL to the HTTPS base URL of this API.'),
      { configError: true }
    );
  }
  return `https://${host}`;
}

function normalizeContentType(value) {
  const base = String(value || '').split(';')[0].trim().toLowerCase();
  return typeAliases[base] || base;
}

function describeR2Error(error) {
  const status = error && error.$metadata && error.$metadata.httpStatusCode;
  const name = (error && (error.Code || error.name)) || 'Error';

  if (error && error.configError) return error.message;
  if (status === 403 || /AccessDenied|InvalidAccessKeyId|SignatureDoesNotMatch/i.test(name)) {
    return `R2 refused the credentials (${name}, HTTP ${status || '403'}). The R2 API token needs Object Read & Write on this bucket, and R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY must belong to the same token.`;
  }
  if (status === 404 || /NoSuchBucket/i.test(name)) {
    return `R2 bucket not found (${name}). Check R2_BUCKET_NAME and R2_ACCOUNT_ID.`;
  }
  if (/ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN/i.test(String(error && error.code))) {
    return `Could not reach the R2 endpoint (${error.code}). Check R2_ENDPOINT / R2_ACCOUNT_ID.`;
  }
  return `R2 check failed (${name}${status ? `, HTTP ${status}` : ''}).`;
}

// R2 connection diagnostic. Checks bucket access without uploading or deleting anything.
router.get('/r2-check', requireUser, async (req, res) => {
  try {
    const s3 = getR2();

    await s3.send(
      new HeadBucketCommand({
        Bucket: bucketName()
      })
    );

    return res.status(200).json({
      ok: true,
      storage: 'cloudflare-r2',
      bucket_accessible: true,
      max_video_bytes: intFromEnv('MAX_VIDEO_BYTES', 209715200, 1, Number.MAX_SAFE_INTEGER),
      upload_url_ttl_seconds: UPLOAD_URL_TTL(),
      playback_url_ttl_seconds: PLAYBACK_URL_TTL()
    });
  } catch (error) {
    console.error('R2 bucket diagnostic failed:', {
      name: error.name,
      code: error.Code || error.code,
      status: error.$metadata?.httpStatusCode,
      message: error.configError ? error.message : undefined
    });

    return res.status(503).json({
      ok: false,
      storage: 'cloudflare-r2',
      bucket_accessible: false,
      error: describeR2Error(error)
    });
  }
});

// Generate an authenticated, temporary upload URL.
router.post('/presign-video', requireUser, async (req, res) => {
  try {
    const { filename, size_bytes } = req.body || {};
    const content_type = normalizeContentType(req.body && req.body.content_type);

    const maxBytes = intFromEnv(
      'MAX_VIDEO_BYTES',
      209715200,
      1,
      Number.MAX_SAFE_INTEGER
    );

    if (
      typeof filename !== 'string' ||
      !filename.trim() ||
      filename.length > 240
    ) {
      return res.status(400).json({
        error: 'A valid filename is required.'
      });
    }

    if (!allowedTypes.has(content_type)) {
      return res.status(415).json({
        error: 'Supported video types: MP4, MOV/QuickTime, and WebM.'
      });
    }

    const size = Number(size_bytes);

    if (!Number.isSafeInteger(size) || size < 1 || size > maxBytes) {
      return res.status(413).json({
        error: `Video must be between 1 byte and ${Math.round(
          maxBytes / 1048576
        )} MiB.`
      });
    }

    // Ownership: the object key is always built from the verified Supabase user id,
    // never from anything the client sends.
    if (!req.user || !uuidPattern.test(String(req.user.id))) {
      return res.status(401).json({ error: 'Could not verify your account.' });
    }

    const ext =
      content_type === 'video/quicktime'
        ? 'mov'
        : content_type === 'video/webm'
          ? 'webm'
          : 'mp4';

    const key = `uploads/${req.user.id}/${randomUUID()}.${ext}`;

    const s3 = getR2();

    // Sign ONLY what a browser reliably sends: the host and Content-Type.
    // - No Metadata: it becomes an x-amz-meta-* header the browser would have to replicate.
    // - No ContentLength by default: browsers set Content-Length themselves and it can differ
    //   from the declared size. Set R2_SIGN_CONTENT_LENGTH=true to bind it to the declared size.
    const commandInput = {
      Bucket: bucketName(),
      Key: key,
      ContentType: content_type
    };

    if (String(process.env.R2_SIGN_CONTENT_LENGTH || '').toLowerCase() === 'true') {
      commandInput.ContentLength = size;
    }

    const expiresIn = UPLOAD_URL_TTL();

    const upload_url = await getSignedUrl(
      s3,
      new PutObjectCommand(commandInput),
      { expiresIn }
    );

    const media_url =
      `${publicApiBase(req)}/api/media/play?key=${encodeURIComponent(key)}`;

    return res.status(200).json({
      upload_url,
      object_key: key,
      media_url,
      expires_in: expiresIn,
      content_type,
      max_bytes: maxBytes,
      headers: { 'Content-Type': content_type },
      required_headers: { 'Content-Type': content_type },
      storage: 'cloudflare-r2'
    });
  } catch (error) {
    console.error('R2 presigned upload setup failed:', error.message);

    return res.status(503).json({
      error: error.configError
        ? error.message
        : 'Secure R2 upload is temporarily unavailable.'
    });
  }
});

// Playback. A <video> element cannot send an Authorization header, so this endpoint is
// unauthenticated, exactly as before. Objects stay private: the bucket is never public, the
// key contains two random UUIDs, and the redirect target is a time-limited signed URL
// (HTTP Range requests, and therefore seeking, go straight to R2 against that URL).
router.get('/play', async (req, res) => {
  try {
    const key =
      typeof req.query.key === 'string'
        ? req.query.key
        : '';

    if (!objectKeyPattern.test(key)) {
      return res.status(400).json({
        error: 'Invalid media key.'
      });
    }

    const s3 = getR2();

    const playbackUrl = await getSignedUrl(
      s3,
      new GetObjectCommand({
        Bucket: bucketName(),
        Key: key
      }),
      {
        expiresIn: PLAYBACK_URL_TTL()
      }
    );

    // The redirect itself must not be cached: every load gets a fresh signed URL.
    res.set('Cache-Control', 'private, no-store, max-age=0');
    res.set('Referrer-Policy', 'no-referrer');

    return res.redirect(302, playbackUrl);
  } catch (error) {
    console.error('R2 playback URL setup failed:', error.message);

    return res.status(503).json({
      error: 'Video playback is temporarily unavailable.'
    });
  }
});

module.exports = router;
