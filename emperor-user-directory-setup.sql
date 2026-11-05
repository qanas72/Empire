-- EMPIRE: secure administrator user directory
-- Run once in Supabase SQL Editor.
-- Returns only profile fields needed by the Emperor Panel. Never exposes auth credentials.

create or replace function public.admin_get_user_directory(p_user_ids uuid[] default null)
returns table (
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  created_at timestamptz,
  is_active boolean,
  membership_type text,
  active_vip_plan text
)
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  return query
  select
    p.id,
    p.username::text,
    coalesce(nullif(trim(p.display_name), ''), p.username)::text,
    p.avatar_url::text,
    p.created_at,
    p.is_active,
    case when vm.user_id is not null then 'VIP' else 'Regular' end::text,
    vm.plan::text
  from public.profiles p
  left join lateral (
    select m.user_id, m.plan
    from public.vip_memberships m
    where m.user_id = p.id
      and lower(coalesce(m.status, '')) = 'active'
      and m.expires_at > now()
    order by m.created_at desc
    limit 1
  ) vm on true
  where p_user_ids is null or p.id = any(p_user_ids)
  order by p.created_at desc;
end;
$$;

revoke all on function public.admin_get_user_directory(uuid[]) from public;
grant execute on function public.admin_get_user_directory(uuid[]) to authenticated;

comment on function public.admin_get_user_directory(uuid[]) is
  'Admin-only profile directory for Emperor Panel and report review; excludes private authentication and payment data.';
