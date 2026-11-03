-- BMN Community: settings/privacy backend. REVIEW BEFORE RUNNING. Additive only: no drops, no deletes, no data changes.
create table if not exists public.user_settings(
  user_id uuid primary key references auth.users(id) on delete cascade,
  private_account boolean not null default false,
  suggest_account boolean not null default true,
  allow_downloads boolean not null default true,
  allow_comments text not null default 'everyone',
  allow_mentions text not null default 'everyone',
  allow_tags text not null default 'everyone',
  who_can_message text not null default 'everyone',
  show_activity_status boolean not null default true,
  read_receipts boolean not null default true,
  language text not null default 'en',
  notif_prefs jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now());
create table if not exists public.user_blocks(
  user_id uuid not null references auth.users(id) on delete cascade,
  target_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('block','mute','restrict')),
  created_at timestamptz not null default now(),
  primary key(user_id,target_id,kind));
alter table public.user_settings enable row level security;
alter table public.user_blocks enable row level security;
create policy "own settings select" on public.user_settings for select using (auth.uid()=user_id);
create policy "own settings insert" on public.user_settings for insert with check (auth.uid()=user_id);
create policy "own settings update" on public.user_settings for update using (auth.uid()=user_id) with check (auth.uid()=user_id);
create policy "own blocks select" on public.user_blocks for select using (auth.uid()=user_id);
create policy "own blocks insert" on public.user_blocks for insert with check (auth.uid()=user_id);
create policy "own blocks delete" on public.user_blocks for delete using (auth.uid()=user_id);
