-- EMPIRE: admin-controlled EMPC reward for each verified paid-video purchase
-- Run in Supabase SQL Editor after the existing EMPC wallet/reward setup.

-- Add a separate admin-controlled reward. Default is disabled and zero until an admin configures it.
insert into public.empire_reward_settings(setting_key, setting_value, is_enabled)
values ('video_purchase_reward', 0, false)
on conflict (setting_key) do nothing;

-- Allow the new reward category while preserving all existing reward types.
do $$
declare r record;
begin
  for r in
    select conname
    from pg_constraint
    where conrelid = 'public.empire_reward_events'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%reward_type%'
  loop
    execute format('alter table public.empire_reward_events drop constraint %I', r.conname);
  end loop;
end;
$$;

alter table public.empire_reward_events
  add constraint empire_reward_events_reward_type_check
  check (reward_type in ('post_like','video_like','signup','referral','video_purchase'));

-- Keep the existing admin-only settings RPC and add the new key to its allowlist.
create or replace function public.admin_update_empire_reward_setting(
 p_key text, p_value numeric, p_enabled boolean
) returns void
language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_old public.empire_reward_settings%rowtype;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_key not in ('post_like_reward','signup_reward','referral_reward_regular','referral_reward_vip','video_purchase_reward') then
   raise exception 'Unknown reward setting';
 end if;
 if p_value is null or p_value < 0 or p_value > 1000000000 then raise exception 'Invalid reward amount'; end if;
 select * into v_old from public.empire_reward_settings where setting_key=p_key for update;
 insert into public.empire_reward_settings(setting_key,setting_value,is_enabled,updated_by,updated_at)
 values(p_key,p_value,p_enabled,auth.uid(),now())
 on conflict(setting_key) do update
 set setting_value=excluded.setting_value,is_enabled=excluded.is_enabled,updated_by=excluded.updated_by,updated_at=now();
 insert into public.empire_reward_setting_logs(setting_key,old_value,new_value,old_enabled,new_enabled,changed_by)
 values(p_key,v_old.setting_value,p_value,v_old.is_enabled,p_enabled,auth.uid());
end;
$$;

revoke all on function public.admin_update_empire_reward_setting(text,numeric,boolean) from public,anon;
grant execute on function public.admin_update_empire_reward_setting(text,numeric,boolean) to authenticated;

-- A purchase can reward only on the first transition to paid.
-- The event key and transaction reference make the payout idempotent.
create or replace function public.pay_video_purchase_reward()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_amount numeric(30,8);
  v_enabled boolean;
  v_treasury public.empire_wallets%rowtype;
  v_wallet public.empire_wallets%rowtype;
  v_event uuid;
  v_key text;
begin
  if new.status <> 'paid' or old.status is not distinct from new.status then
    return new;
  end if;

  if new.user_id is null or new.video_id is null then
    return new;
  end if;

  select setting_value, is_enabled
    into v_amount, v_enabled
  from public.empire_reward_settings
  where setting_key='video_purchase_reward';

  if not coalesce(v_enabled,false) or coalesce(v_amount,0) <= 0 then
    return new;
  end if;

  v_key := 'video-purchase-reward:' || new.id::text;

  insert into public.empire_reward_events(
    event_key, recipient_user_id, source_user_id, reward_type, amount
  ) values (
    v_key, new.user_id, null, 'video_purchase', v_amount
  )
  on conflict(event_key) do nothing
  returning id into v_event;

  if v_event is null then
    return new;
  end if;

  select * into v_treasury
  from public.empire_wallets
  where wallet_type='treasury' and user_id is null
  for update;

  select * into v_wallet
  from public.empire_wallets
  where wallet_type='user' and user_id=new.user_id
  for update;

  -- Do not block an already verified video payment if the reward treasury
  -- is temporarily insufficient; remove the provisional event and skip payout.
  if v_treasury.id is null or v_wallet.id is null or v_treasury.balance < v_amount then
    delete from public.empire_reward_events where id=v_event;
    return new;
  end if;

  update public.empire_wallets
    set balance=balance-v_amount
  where id=v_treasury.id;

  update public.empire_wallets
    set balance=balance+v_amount
  where id=v_wallet.id;

  insert into public.empire_transactions(
    from_wallet_id,to_wallet_id,amount,transaction_type,
    description,external_reference,created_by
  ) values (
    v_treasury.id,v_wallet.id,v_amount,'reward',
    'EMPC reward for verified paid-video purchase',
    v_key,new.user_id
  );

  update public.empire_reward_events
    set transaction_id=(
      select id from public.empire_transactions where external_reference=v_key
    )
  where id=v_event;

  return new;
end;
$$;

drop trigger if exists empire_paid_video_purchase_reward on public.purchases;
create trigger empire_paid_video_purchase_reward
after update of status on public.purchases
for each row
when (new.status='paid' and old.status is distinct from new.status)
execute function public.pay_video_purchase_reward();

revoke all on function public.pay_video_purchase_reward() from public,anon,authenticated;

comment on function public.pay_video_purchase_reward() is
  'Transfers the admin-configured EMPC reward from the internal treasury to a buyer once when a paid-video purchase becomes paid.';
