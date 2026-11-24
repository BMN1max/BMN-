-- Test-only. The production audit (2026-11-23) showed tables that the repo baseline does not contain.
-- They are recreated here with the EXACT production shape so the migrations are tested against reality:
-- user_blocks(user_id,target_id,kind) and user_settings(... who_can_message, read_receipts, show_activity_status ...).
-- The three "own ..." policies mirror production (role public, auth.uid() = user_id).
CREATE TABLE public.user_blocks (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  target_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  kind text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, target_id, kind),
  CONSTRAINT user_blocks_kind_check CHECK (kind = ANY (ARRAY['block','mute','restrict'])));
ALTER TABLE public.user_blocks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own blocks select" ON public.user_blocks FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "own blocks insert" ON public.user_blocks FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own blocks delete" ON public.user_blocks FOR DELETE USING (auth.uid() = user_id);
CREATE TABLE public.user_settings (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  private_account boolean NOT NULL DEFAULT false, suggest_account boolean NOT NULL DEFAULT true,
  allow_downloads boolean NOT NULL DEFAULT true, allow_comments text NOT NULL DEFAULT 'everyone',
  allow_mentions text NOT NULL DEFAULT 'everyone', allow_tags text NOT NULL DEFAULT 'everyone',
  who_can_message text NOT NULL DEFAULT 'everyone', show_activity_status boolean NOT NULL DEFAULT true,
  read_receipts boolean NOT NULL DEFAULT true, language text NOT NULL DEFAULT 'en',
  notif_prefs jsonb NOT NULL DEFAULT '{}'::jsonb, updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own settings select" ON public.user_settings FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "own settings insert" ON public.user_settings FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "own settings update" ON public.user_settings FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
GRANT ALL ON public.user_blocks, public.user_settings TO anon, authenticated, service_role;
-- a pre-existing "mute" row must never act as a block
