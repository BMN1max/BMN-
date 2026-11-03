# BMN patch, honest status

## Done in index.html (syntax-checked only; NOT tested against live Supabase)
- Owner creator profile hides Followers/Following/Likes in both profile layers; follow system untouched.
- Hidden stats replaced by a compact "BMN CREATOR" tile (dragon-inspired mark, dark/light aware).
- Follow handler no longer edits the wrong tile.
- guest() no longer overwrites a signed-in account (Guest fix; remaining Guest default only applies when signed out).

## Not done (needs backend access or a larger rewrite, so I did not fake it)
- Avatar/video upload fixes (need your storage policies + the real console error)
- Inbox rebuild, full settings centre, i18n, search overlay, new verification badge, new icons/dock, light-mode contrast consolidation (~60 stacked style blocks)
- migration-REVIEW-FIRST.sql: tables for settings/blocks/mutes with RLS. Not executed. Review, then run.

Please test in a browser before deploying; keep your original index.html as backup.
