-- =====================================================================
-- M0  notifications.message column (compat fix)
-- STATUS: PROPOSED. Not run anywhere. Review first, then run in the Supabase SQL editor.
-- PURPOSE  The baseline `notifications` table has no `message` column, but the follow/like
--          notification triggers and the Batch 2 client write one. Production probably has it.
--          This adds it only if it is missing.
-- OBJECTS  public.notifications.message (text, nullable)
-- SECURITY No policy changes. Existing RLS keeps applying.
-- IDEMPOTENT  Yes (ADD COLUMN IF NOT EXISTS).
-- =====================================================================
ALTER TABLE public.notifications ADD COLUMN IF NOT EXISTS message text;

-- ROLLBACK-BEGIN
-- (nothing to roll back: the column is nullable and harmless. To remove it anyway:)
-- ALTER TABLE public.notifications DROP COLUMN IF EXISTS message;
-- ROLLBACK-END

-- VERIFY-BEGIN
-- select column_name, data_type from information_schema.columns
--  where table_schema='public' and table_name='notifications' and column_name='message';
-- VERIFY-END
