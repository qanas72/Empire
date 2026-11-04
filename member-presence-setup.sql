-- EMPIRE member online/offline presence
create table if not exists public.user_presence (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_seen timestamptz not null default now()
);

alter table public.user_presence enable row level security;

drop policy if exists "Presence is publicly readable" on public.user_presence;
create policy "Presence is publicly readable"
on public.user_presence for select
to anon, authenticated
using (true);

drop policy if exists "Users can insert own presence" on public.user_presence;
create policy "Users can insert own presence"
on public.user_presence for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "Users can update own presence" on public.user_presence;
create policy "Users can update own presence"
on public.user_presence for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

grant select on public.user_presence to anon, authenticated;
grant insert, update on public.user_presence to authenticated;
