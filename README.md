# BMN TikTok-style Full App Parity V4

This build updates the supplied BMN `index.html` with a much closer TikTok-inspired mobile app layout while retaining BMN branding and the existing Supabase-backed post, profile, like, comment, save, repost, follow, inbox and create controls. The floating BMN dock remains.

## Changes in this pass
- Replaces the portfolio header in Community app mode with an overlaid For You / Following header, LIVE entry point, and search control.
- Makes real backend-backed post cards full-viewport vertical snap slides with media covering the viewport.
- Repositions existing action buttons into a right-side rail, with creator avatar/follow action, like, comments, save, and share.
- Keeps the existing real counts and event handlers; it does not add sample creators or fabricated engagement numbers.
- Adds creator search in Discover and TikTok-like screen title styling for Discover, Create, Inbox, and Profile.
- Keeps the floating Home / Discover / Create / Inbox / Profile dock and safe-area support.
- Provides a clear message that LIVE streaming is not enabled rather than pretending it works.

## Important limitations
- This is a front-end layout/interaction pass. The app still depends on the existing Supabase schema, storage bucket, RLS policies, and configured Realtime. No schema changes are assumed.
- Persistent Stories cannot be enabled from the current known schema without a real Stories backend table/storage/policies; this build does not fabricate story rings or story posts.
- Exact pixel-for-pixel duplication of TikTok across every device is not guaranteed. TikTok's interface changes by region, app version, account and device. This is a high-fidelity adaptation using the supplied HTML references, with BMN branding and the requested floating dock.
- Automated validation covers HTML parsing and JavaScript syntax only; a live iPhone/browser and Supabase regression test is still needed.
