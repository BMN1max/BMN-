# BMN video pipeline (HLS, posters, Data Saver)

Originals stay exactly where they are: `uploads/<user>/<video>.mp4|mov|webm` in your private R2 bucket.
Everything new is *derived* from them, under `hls/<user>/<video>/`. Existing posts keep their
`…/api/media/play?key=…` URLs; those URLs still work and are the last-resort fallback.

## How it works

1. Browser uploads the original to R2 (unchanged), then calls `POST /api/media/complete`.
2. The API adds a row to `media_assets` (Supabase). A **worker** (separate Render service with ffmpeg)
   claims it, downloads the original read-only, and writes: HLS renditions (360/540/720/1080 by short
   side, never upscaled, H.264+AAC, 4 s segments), `poster.jpg`, `mp4_main.mp4`, `mp4_low.mp4`.
3. The feed asks `GET /api/media/info?keys=…` (one request for a whole screen). When a video is `ready`
   the player uses HLS (`/hls/master?key=…&cap=<px>`), else the compressed MP4, else the original.
4. Segment bytes go straight from R2 to the phone (signed URLs); the API only serves tiny playlists.

Playback order in the browser: native HLS (Safari/iOS/PWA, Chromium with built-in HLS) → hls.js (loaded
only when needed) → compressed MP4 → original. Any error or a 10 s stall moves to the next step.

Data behaviour: only videos near the screen get a source; a video that leaves the screen is paused and,
when far away, its source is removed. Nothing but a small poster is fetched for videos you have not
played (unless you chose High quality or are on Wi-Fi in Auto, which may preload the first bytes).

Settings → App → **Video quality**: Auto (follows network / screen; Data saver switch forces low),
Low data (360p), High (up to 1080p). Original-quality download (menu → "Download original quality")
is only offered to the uploader; it is signed, 5 minutes, `attachment`.

## One-time setup (in this order)

1. **Supabase** → SQL Editor → run `supabase/migrations/20261109090000_media_assets.sql`.
2. **R2 bucket CORS** (required for HLS in Chromium/hls.js; without it the player just falls back to MP4):
   ```json
   [{"AllowedOrigins":["https://bmnng.vercel.app"],
     "AllowedMethods":["GET","HEAD","PUT"],
     "AllowedHeaders":["*"],
     "ExposeHeaders":["Content-Length","Content-Range","Accept-Ranges","ETag"],
     "MaxAgeSeconds":3600}]
   ```
   (keep any origins/methods you already have for uploads, e.g. localhost for testing).
3. **Render API service**: deploy the updated `server.js`, `routes/media.js`, `video-keys.js`, `hls.js`, `package.json`.
   No new env vars are required. Optional: `ALLOW_ORIGINAL_DOWNLOAD_FOR_ALL=true`.
4. **Render Background Worker** (new service, Docker): same repo, Dockerfile path `Dockerfile.worker`.
   Env: same `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`,
   `R2_SECRET_ACCESS_KEY`, `R2_BUCKET_NAME` as the API. Optional: `HLS_MAX_SHORT_SIDE` (default 1080),
   `FFMPEG_PRESET` (default `veryfast`), `HLS_MAX_DURATION_SECONDS` (3600), `MEDIA_JOB_MAX_ATTEMPTS` (3).
5. **Vercel**: upload the new `index.html`.
6. Old videos: `npm run backfill:media` (locally or as a one-off job) queues every existing R2 video; the
   worker processes them. (They are also queued automatically when a signed-in user scrolls past them.)

Optional hardening: self-host hls.js (`window.BMN_HLS_JS_URL='/vendor/hls.min.js'`). By default it is loaded
only on browsers without native HLS from jsDelivr/unpkg, version-pinned (1.5.17), without SRI.

## Costs / extra services
- **Render Background Worker**: required, new paid service. ffmpeg needs real CPU: plan for a 1 CPU / 2 GB
  instance (Render "Standard", about $25/month at the time of writing) — the 512 MB Starter will be slow or
  run out of memory on 1080p. Check Render's current pricing. Roughly 1–2× realtime per minute of video on 1 CPU.
- **Cloudflare R2**: stores originals **plus** about 1.5–3× extra for renditions and MP4s (≈ $0.015/GB-month
  beyond the 10 GB free tier). Egress is free. More requests (segments) = Class B reads ($0.36 per million,
  first 10 M/month free) — check current R2 pricing.
- **Supabase**: one small table; no extra cost expected.
- Nothing else (no Cloudflare Stream / Mux needed).

## Known limits
- Tested in Chromium only (native HLS). Safari/iOS, the hls.js path, real R2, real Supabase/PostgREST and
  the real AWS SDK signing were NOT exercised here; they are standard but verify on a phone after deploying.
- HDR sources use ffmpeg `zscale` tone-mapping when available (default in the Docker image) — untested.
- Videos longer than `HLS_MAX_DURATION_SECONDS` are left on the original file.
- Posts whose media is not an R2 `/api/media/play` link (Supabase storage, external) are untouched.
