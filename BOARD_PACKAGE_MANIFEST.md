# BMN Board — complete Board-only file package

This package contains all Board-specific new files and Board test/support files from the supplied repository ZIP.

## New files
- `bmn-board.js`
- `bmn-board.css`
- `supabase/proposed/B1_board_core.sql` (already applied and verified in the user's Supabase project; do not run again just for deployment)
- `docs/board/BMN_BOARD_AUDIT_READONLY.sql` (read-only audit)
- `docs/board/BOARD_README.md`
- `TEST_REPORT_BOARD.md`
- `tests/board/**` (Board SQL/browser test harness, outputs, and screenshots)

## Existing file that Claude modified
- `index.html` — intentionally NOT included as a replacement. It is an existing production file. Claude's Board README describes four integration edits: update the B-button handler/label, load `bmn-board.css` and `bmn-board.js`, and add the About BMN / Open BMN Board settings links. Merge those changes into the current GitHub version rather than blindly replacing it with the ZIP copy.

## Deployment note
Only `bmn-board.js`, `bmn-board.css`, and the carefully merged `index.html` are needed for the live frontend. SQL, docs, and tests are supporting/source-control files, not files that need to be served by Vercel. The SQL migration has already been run and verified; do not rerun it without a specific reason.
