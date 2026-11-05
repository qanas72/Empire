-- EMPIRE: secure user follow relationships
-- Run once in Supabase SQL Editor.

create table if not exists public.user_follows (
  follower_id uuid not null references auth.users(id) on delete cascade,
  following_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint user_follows_pkey primary key (follower_id, following_id),
  constraint user_follows_no_self check (follower_id <> following_id)
);

create index if not exists user_follows_following_idx
  on public.user_follows (following_id, created_at desc);

create index if not exists user_follows_follower_idx
  on public.user_follows (follower_id, created_at desc);

alter table public.user_follows enable row level security;

drop policy if exists "Authenticated users can view follows" on public.user_follows;
create policy "Authenticated users can view follows"
  on public.user_follows
  for select
  to authenticated
  using (true);

drop policy if exists "Users can follow from their own account" on public.user_follows;
create policy "Users can follow from their own account"
  on public.user_follows
  for insert
  to authenticated
  with check (
    follower_id = (select auth.uid())
    and follower_id <> following_id
  );

drop policy if exists "Users can unfollow from their own account" on public.user_follows;
create policy "Users can unfollow from their own account"
  on public.user_follows
  for delete
  to authenticated
  using (follower_id = (select auth.uid()));

grant select, insert, delete on public.user_follows to authenticated;
