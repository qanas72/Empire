-- EMPIRE VIP plan EMPC reward controls
-- Run this migration in Supabase SQL Editor.
begin;

alter table public.empire_vip_plan_settings
  add column if not exists reward_empc numeric(20,8) not null default 0,
  add column if not exists reward_enabled boolean not null default true;

update public.empire_vip_plan_settings
set reward_empc = case plan_key
  when 'vip-monthly' then 4000
  when 'vip-quarterly' then 14000
  when 'vip-semiannual' then 27000
  when 'vip-yearly' then 550000
  else reward_empc
end
where reward_empc = 0;

create or replace function public.admin_update_empire_vip_plan_reward(
  p_plan_key text,
  p_reward_empc numeric,
  p_reward_enabled boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  if p_plan_key not in ('vip-monthly','vip-quarterly','vip-semiannual','vip-yearly') then
    raise exception 'Invalid VIP plan';
  end if;

  if p_reward_empc is null or p_reward_empc < 0 or p_reward_empc > 1000000000 then
    raise exception 'Invalid EMPC reward amount';
  end if;

  if p_reward_enabled is null then
    raise exception 'Reward enabled status is required';
  end if;

  update public.empire_vip_plan_settings
  set reward_empc = p_reward_empc,
      reward_enabled = p_reward_enabled,
      updated_by = auth.uid(),
      updated_at = now()
  where plan_key = p_plan_key;

  if not found then
    raise exception 'VIP plan not found';
  end if;
end;
$$;

revoke all on function public.admin_update_empire_vip_plan_reward(text,numeric,boolean) from public, anon;
grant execute on function public.admin_update_empire_vip_plan_reward(text,numeric,boolean) to authenticated;

commit;
