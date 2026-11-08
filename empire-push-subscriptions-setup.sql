-- EMPIRE Web Push subscriptions
create table if not exists public.empire_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  expiration_time bigint,
  user_agent text,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create index if not exists empire_push_subscriptions_user_enabled_idx
  on public.empire_push_subscriptions(user_id, enabled);

alter table public.empire_push_subscriptions enable row level security;

drop policy if exists "Users can view own push subscriptions" on public.empire_push_subscriptions;
create policy "Users can view own push subscriptions"
  on public.empire_push_subscriptions for select
  to authenticated using (auth.uid() = user_id);

drop policy if exists "Users can register own push subscriptions" on public.empire_push_subscriptions;
create policy "Users can register own push subscriptions"
  on public.empire_push_subscriptions for insert
  to authenticated with check (auth.uid() = user_id);

drop policy if exists "Users can update own push subscriptions" on public.empire_push_subscriptions;
create policy "Users can update own push subscriptions"
  on public.empire_push_subscriptions for update
  to authenticated using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Users can delete own push subscriptions" on public.empire_push_subscriptions;
create policy "Users can delete own push subscriptions"
  on public.empire_push_subscriptions for delete
  to authenticated using (auth.uid() = user_id);

grant select, insert, update, delete on public.empire_push_subscriptions to authenticated;
