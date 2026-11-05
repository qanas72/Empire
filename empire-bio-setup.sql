-- EMPIRE: optional public member Bio
-- Run once in Supabase SQL Editor.

alter table public.profiles
  add column if not exists bio text;

comment on column public.profiles.bio is
  'Optional member-written public biography. Members may leave it empty.';

create or replace view public.public_user_profiles
with (security_barrier = true)
as
select
  p.id,
  p.username,
  coalesce(nullif(trim(p.display_name), ''), p.username) as display_name,
  p.avatar_url,
  p.created_at,
  case
    when vm.user_id is not null then 'VIP'
    else 'Regular'
  end as membership_type,
  vm.plan as active_vip_plan,
  p.bio
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
where p.is_active = true
  and p.id not in (
    '8166f8a9-fdc3-43a4-85c7-53ec1dbbde0e'::uuid,
    '7c5f5c13-b106-4c7c-9bd5-9339576bfe7a'::uuid
  );

comment on view public.public_user_profiles is
  'Safe public directory; excludes administrator accounts and exposes only selected public profile fields including optional Bio.';

revoke all on public.public_user_profiles from public;
grant select on public.public_user_profiles to anon, authenticated;
