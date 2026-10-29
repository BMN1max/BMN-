# BMN Community — Cloudflare R2 video route patch

This patch replaces `src/routes/media.js` in the existing Node API. It is designed to keep Supabase auth/database and existing Supabase Storage media untouched. New video uploads use R2; the existing HTML already calls `POST /api/media/presign-video` and uploads the returned `upload_url` with a browser `PUT`, so the upload UI may not need a change if `window.BMN_API_BASE_URL` points to this API.

## Important before deploying

1. Make a backup/branch of the current GitHub repository.
2. Confirm the deployed API's actual entry point. Your `package.json` says `src/server.js`, so this patch is placed at `src/routes/media.js`.
3. Replace that file with the provided `media.js` only after checking it against the current repository version.
4. Add the environment variables below to the backend deployment's server-side environment settings. Do not put secrets in `index.html`, GitHub, or browser JavaScript.
5. Configure R2 bucket CORS to allow your exact website origin and `PUT` from the browser, with `Content-Type` allowed. Do not enable public bucket access for this design.
6. Deploy and test with a small, non-sensitive video first. Check upload, playback, and that existing Supabase video posts still play before using large files.

## Required backend environment variables

- `R2_ACCOUNT_ID`: Cloudflare account ID.
- `R2_ACCESS_KEY_ID`: R2 S3 API access key ID.
- `R2_SECRET_ACCESS_KEY`: matching R2 secret access key.
- `R2_BUCKET_NAME`: `bmn-community-media`.
- `R2_ENDPOINT`: `https://<account-id>.r2.cloudflarestorage.com` (account endpoint only; do not append the bucket name).
- `PUBLIC_API_URL`: HTTPS base URL of the deployed API, with no trailing slash. This is used to create the stored playback URL.
- `MAX_VIDEO_BYTES`: optional; defaults to 209715200 bytes (200 MiB).

`AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET_NAME`, and `CDN_DISTRIBUTION_DOMAIN` are no longer used by this route.

## How playback works

The R2 bucket remains private. A published post stores a BMN API playback URL containing a random UUID-based object key. `/api/media/play` returns a short-lived signed R2 URL by redirecting the viewer. The raw R2 endpoint and credentials are not put in the page. Treat the post URL as a bearer link: anyone who can obtain it can request playback while the object exists. This endpoint does not yet query the posts table to verify that a post is still published; if unpublishing must immediately revoke playback, add a database-backed post/key check before enabling production use.

## Important deployment note

The code shown in the existing `server.js` creates a long-running HTTP server and Socket.IO connection. Confirm that this API is actually deployed in a runtime that supports that server and that `/api/media/*` routes reach it. A static Vercel website project alone does not run this backend. Do not assume the route is live merely because the frontend deploy succeeded.

## Existing media and egress

This patch does not migrate, overwrite, or delete any existing Supabase Storage object. Existing posts that store Supabase URLs/`storage:` references should continue using the existing frontend resolver. Supabase egress will only fall for playback switched to R2; uploads alone do not reduce playback egress.
