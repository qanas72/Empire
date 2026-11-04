-- EMPIRE administrator access migration
-- Run in Supabase SQL Editor after confirming the second account exists.
-- Both accounts must have an active profiles row with the exact username shown.

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_active = true
      and lower(p.username) in ('qanas', 'emperor')
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

