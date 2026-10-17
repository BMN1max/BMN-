-- Apply only after reviewing Stripe Connect onboarding and country eligibility.
-- Regular users must not write these payout fields; manage them through trusted server code.
create table if not exists public.creator_payout_accounts (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  stripe_account_id text unique not null,
  charges_enabled boolean not null default false,
  payouts_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.creator_payout_accounts enable row level security;
revoke all on public.creator_payout_accounts from anon, authenticated;
grant select, insert, update, delete on public.creator_payout_accounts to service_role;

create table if not exists public.creator_tips (
  id bigint generated always as identity primary key,
  stripe_checkout_session_id text unique not null,
  sender_user_id uuid not null references auth.users(id) on delete restrict,
  creator_user_id uuid not null references public.profiles(id) on delete restrict,
  amount_total bigint not null check (amount_total > 0),
  currency text not null,
  payment_status text not null check (payment_status in ('paid')),
  paid_at timestamptz not null,
  created_at timestamptz not null default now()
);
alter table public.creator_tips enable row level security;
revoke all on public.creator_tips from anon, authenticated;
grant select, insert, update on public.creator_tips to service_role;
