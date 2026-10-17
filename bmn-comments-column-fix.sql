-- BMN Community: safe, additive fix for the missing comments.content column.
-- Run in Supabase Dashboard -> SQL Editor only after reviewing this script.
-- It does not drop tables, delete comments, or change existing RLS policies.

ALTER TABLE public.comments
  ADD COLUMN IF NOT EXISTS content text;

-- If this project used another common name for the comment body, copy it into
-- content without overwriting any content that is already present.
DO $$
DECLARE
  source_column text;
BEGIN
  FOREACH source_column IN ARRAY ARRAY['body', 'comment_text', 'text', 'comment'] LOOP
    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'comments'
        AND column_name = source_column
    ) THEN
      EXECUTE format(
        'UPDATE public.comments SET content = %I::text WHERE content IS NULL AND %I IS NOT NULL',
        source_column, source_column
      );
      EXIT;
    END IF;
  END LOOP;
END $$;

-- Ask PostgREST/Supabase API to refresh its cached table schema.
NOTIFY pgrst, 'reload schema';
