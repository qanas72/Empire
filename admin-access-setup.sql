-- EMPIRE administrator access migration
-- Only these two verified account UUIDs may access administration.
-- Matching a username such as "qanas" or "Emperor" is NOT sufficient.

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() in (
    '8166f8a9-fdc3-43a4-85c7-53ec1dbbde0e'::uuid,
    '7c5f5c13-b106-4c7c-9bd5-9339576bfe7a'::uuid
  )
  and exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_active = true
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;
