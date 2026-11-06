-- EMPIRE Support Requests
-- Run once in Supabase SQL Editor.
create table if not exists public.support_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  user_email text,
  category text not null default 'general',
  subject text not null check (char_length(subject) between 1 and 140),
  message text not null check (char_length(message) between 1 and 5000),
  status text not null default 'new' check (status in ('new','in_progress','resolved')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists support_requests_created_at_idx
  on public.support_requests (created_at desc);
create index if not exists support_requests_user_id_idx
  on public.support_requests (user_id);
alter table public.support_requests enable row level security;
drop policy if exists "Users can submit their own support requests" on public.support_requests;
create policy "Users can submit their own support requests"
  on public.support_requests for insert to authenticated
  with check (auth.uid() = user_id);
drop policy if exists "Admins can view support requests" on public.support_requests;
create policy "Admins can view support requests"
  on public.support_requests for select to authenticated
  using (public.is_admin() = true);
drop policy if exists "Admins can update support requests" on public.support_requests;
create policy "Admins can update support requests"
  on public.support_requests for update to authenticated
  using (public.is_admin() = true)
  with check (public.is_admin() = true);
