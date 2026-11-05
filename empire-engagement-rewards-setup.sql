-- EMPIRE engagement, signup and referral rewards
-- Run once in Supabase SQL Editor after the EMPC wallet and publishing setup scripts.

create table if not exists public.empire_reward_settings (
  setting_key text primary key,
  setting_value numeric(30,8) not null check (setting_value >= 0),
  is_enabled boolean not null default true,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

insert into public.empire_reward_settings(setting_key,setting_value,is_enabled) values
 ('post_like_reward',1,true),
 ('signup_reward',10,true),
 ('referral_reward_regular',50,true),
 ('referral_reward_vip',100,true),
 ('like_reward_enabled',1,true),
 ('signup_reward_enabled',1,true),
 ('referral_reward_enabled',1,true)
on conflict(setting_key) do nothing;

create table if not exists public.empire_reward_setting_logs (
 id uuid primary key default gen_random_uuid(),
 setting_key text not null,
 old_value numeric(30,8),
 new_value numeric(30,8) not null,
 old_enabled boolean,
 new_enabled boolean not null,
 changed_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);

alter table public.empire_reward_settings enable row level security;
alter table public.empire_reward_setting_logs enable row level security;
drop policy if exists "Admins read reward settings" on public.empire_reward_settings;
create policy "Admins read reward settings" on public.empire_reward_settings for select to authenticated using(public.is_admin());
drop policy if exists "Admins read reward setting logs" on public.empire_reward_setting_logs;
create policy "Admins read reward setting logs" on public.empire_reward_setting_logs for select to authenticated using(public.is_admin());
revoke all on public.empire_reward_settings, public.empire_reward_setting_logs from anon, authenticated;
grant select on public.empire_reward_settings, public.empire_reward_setting_logs to authenticated;

create or replace function public.admin_update_empire_reward_setting(
 p_key text, p_value numeric, p_enabled boolean
) returns void
language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_old public.empire_reward_settings%rowtype;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_key not in ('post_like_reward','signup_reward','referral_reward_regular','referral_reward_vip',
                  'like_reward_enabled','signup_reward_enabled','referral_reward_enabled') then
   raise exception 'Unknown reward setting';
 end if;
 if p_value is null or p_value < 0 or p_value > 1000000000 then raise exception 'Invalid reward amount'; end if;
 if p_key like '%_enabled' and p_value not in (0,1) then raise exception 'Invalid enabled setting'; end if;
 select * into v_old from public.empire_reward_settings where setting_key=p_key for update;
 insert into public.empire_reward_settings(setting_key,setting_value,is_enabled,updated_by,updated_at)
 values(p_key,p_value,p_enabled,auth.uid(),now())
 on conflict(setting_key) do update set setting_value=excluded.setting_value,is_enabled=excluded.is_enabled,updated_by=excluded.updated_by,updated_at=now();
 insert into public.empire_reward_setting_logs(setting_key,old_value,new_value,old_enabled,new_enabled,changed_by)
 values(p_key,v_old.setting_value,p_value,v_old.is_enabled,p_enabled,auth.uid());
end;
$$;
revoke all on function public.admin_update_empire_reward_setting(text,numeric,boolean) from public,anon;
grant execute on function public.admin_update_empire_reward_setting(text,numeric,boolean) to authenticated;

create table if not exists public.community_post_reactions (
 post_id uuid not null references public.community_posts(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 reaction text not null check(reaction in ('like','dislike')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 primary key(post_id,user_id)
);
create index if not exists community_post_reactions_post_idx on public.community_post_reactions(post_id,reaction);
alter table public.community_post_reactions enable row level security;
drop policy if exists "Public can read post reaction counts" on public.community_post_reactions;
create policy "Public can read post reaction counts" on public.community_post_reactions for select using(true);
revoke all on public.community_post_reactions from anon,authenticated;
grant select on public.community_post_reactions to anon,authenticated;

create table if not exists public.empire_reward_events (
 id uuid primary key default gen_random_uuid(),
 event_key text not null unique,
 recipient_user_id uuid not null references auth.users(id) on delete cascade,
 source_user_id uuid references auth.users(id) on delete set null,
 reward_type text not null check(reward_type in ('post_like','signup','referral')),
 amount numeric(30,8) not null check(amount>0),
 transaction_id uuid references public.empire_transactions(id),
 created_at timestamptz not null default now()
);
create index if not exists empire_reward_events_recipient_idx on public.empire_reward_events(recipient_user_id,created_at desc);
alter table public.empire_reward_events enable row level security;
drop policy if exists "Users read own reward history" on public.empire_reward_events;
create policy "Users read own reward history" on public.empire_reward_events for select to authenticated using(recipient_user_id=auth.uid() or public.is_admin());
revoke all on public.empire_reward_events from anon,authenticated;
grant select on public.empire_reward_events to authenticated;

create or replace function public.toggle_community_post_reaction(p_post_id uuid,p_reaction text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_user uuid:=auth.uid(); v_author uuid; v_existing text; v_like_count integer; v_dislike_count integer;
 v_amount numeric(30,8); v_enabled boolean; v_treasury public.empire_wallets%rowtype; v_wallet public.empire_wallets%rowtype; v_event uuid; v_rewarded boolean:=false;
begin
 if v_user is null then raise exception 'Sign in required'; end if;
 if p_reaction not in ('like','dislike') then raise exception 'Invalid reaction'; end if;
 select author_id into v_author from public.community_posts where id=p_post_id and is_removed=false;
 if not found then raise exception 'Publication not found'; end if;
 if v_author=v_user then raise exception 'You cannot react to your own publication'; end if;
 select reaction into v_existing from public.community_post_reactions where post_id=p_post_id and user_id=v_user for update;
 if v_existing=p_reaction then
   delete from public.community_post_reactions where post_id=p_post_id and user_id=v_user;
 else
   insert into public.community_post_reactions(post_id,user_id,reaction)
   values(p_post_id,v_user,p_reaction)
   on conflict(post_id,user_id) do update set reaction=excluded.reaction,updated_at=now();
 end if;
 if p_reaction='like' and v_existing is distinct from 'like' then
   select setting_value,is_enabled into v_amount,v_enabled from public.empire_reward_settings where setting_key='post_like_reward';
   if coalesce(v_enabled,false) and coalesce(v_amount,0)>0 then
     insert into public.empire_reward_events(event_key,recipient_user_id,source_user_id,reward_type,amount)
     values('post-like:'||p_post_id::text||':'||v_user::text,v_author,v_user,'post_like',v_amount)
     on conflict(event_key) do nothing returning id into v_event;
     if v_event is not null then
       select * into v_treasury from public.empire_wallets where wallet_type='treasury' and user_id is null for update;
       select * into v_wallet from public.empire_wallets where user_id=v_author and wallet_type='user' for update;
       if v_treasury.id is not null and v_wallet.id is not null and v_treasury.balance>=v_amount then
         update public.empire_wallets set balance=balance-v_amount where id=v_treasury.id;
         update public.empire_wallets set balance=balance+v_amount where id=v_wallet.id;
         insert into public.empire_transactions(from_wallet_id,to_wallet_id,amount,transaction_type,description,external_reference,created_by)
         values(v_treasury.id,v_wallet.id,v_amount,'reward','EMPC reward for receiving a publication like','post-like:'||p_post_id::text||':'||v_user::text,v_user);
         update public.empire_reward_events set transaction_id=(select id from public.empire_transactions where external_reference='post-like:'||p_post_id::text||':'||v_user::text)
         where id=v_event;
         v_rewarded:=true;
       else
         delete from public.empire_reward_events where id=v_event;
       end if;
     end if;
   end if;
 end if;
 select count(*) filter(where reaction='like'),count(*) filter(where reaction='dislike')
 into v_like_count,v_dislike_count from public.community_post_reactions where post_id=p_post_id;
 return jsonb_build_object('like_count',coalesce(v_like_count,0),'dislike_count',coalesce(v_dislike_count,0),
   'my_reaction',case when v_existing=p_reaction then null else p_reaction end,'rewarded',v_rewarded);
end;
$$;
revoke all on function public.toggle_community_post_reaction(uuid,text) from public,anon;
grant execute on function public.toggle_community_post_reaction(uuid,text) to authenticated;

-- Referral codes are opaque, non-sensitive public invitation identifiers.
create table if not exists public.empire_referral_codes (
 user_id uuid primary key references auth.users(id) on delete cascade,
 code text not null unique,
 created_at timestamptz not null default now()
);
create table if not exists public.empire_referrals (
 id uuid primary key default gen_random_uuid(),
 referrer_user_id uuid not null references auth.users(id) on delete cascade,
 referred_user_id uuid not null unique references auth.users(id) on delete cascade,
 referral_code text not null,
 status text not null default 'pending' check(status in ('pending','paid')),
 reward_amount numeric(30,8),
 paid_at timestamptz,
 created_at timestamptz not null default now(),
 constraint empire_referral_no_self check(referrer_user_id<>referred_user_id)
);
alter table public.empire_referral_codes enable row level security;
alter table public.empire_referrals enable row level security;
drop policy if exists "Users can read referral codes" on public.empire_referral_codes;
create policy "Users can read referral codes" on public.empire_referral_codes for select to authenticated using(true);
drop policy if exists "Users read own referrals" on public.empire_referrals;
create policy "Users read own referrals" on public.empire_referrals for select to authenticated using(referrer_user_id=auth.uid() or referred_user_id=auth.uid() or public.is_admin());
revoke all on public.empire_referral_codes,public.empire_referrals from anon,authenticated;
grant select on public.empire_referral_codes,public.empire_referrals to authenticated;

create or replace function public.get_my_empire_referral_code()
returns text language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_code text;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 insert into public.empire_referral_codes(user_id,code)
 values(auth.uid(),upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)))
 on conflict(user_id) do nothing;
 select code into v_code from public.empire_referral_codes where user_id=auth.uid();
 return v_code;
end;
$$;
revoke all on function public.get_my_empire_referral_code() from public,anon;
grant execute on function public.get_my_empire_referral_code() to authenticated;

create or replace function public.claim_empire_signup_reward()
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_user uuid:=auth.uid(); v_confirmed timestamptz; v_meta jsonb; v_amount numeric(30,8); v_enabled boolean;
 v_treasury public.empire_wallets%rowtype; v_wallet public.empire_wallets%rowtype; v_event uuid; v_code text; v_referrer uuid;
begin
 if v_user is null then raise exception 'Sign in required'; end if;
 select email_confirmed_at,raw_user_meta_data into v_confirmed,v_meta from auth.users where id=v_user;
 if v_confirmed is null then raise exception 'Confirm your email before claiming the signup reward'; end if;
 select setting_value,is_enabled into v_amount,v_enabled from public.empire_reward_settings where setting_key='signup_reward';
 if coalesce(v_enabled,false) and coalesce(v_amount,0)>0 then
   insert into public.empire_reward_events(event_key,recipient_user_id,reward_type,amount)
   values('signup:'||v_user::text,v_user,'signup',v_amount)
   on conflict(event_key) do nothing returning id into v_event;
   if v_event is not null then
     select * into v_treasury from public.empire_wallets where wallet_type='treasury' and user_id is null for update;
     select * into v_wallet from public.empire_wallets where user_id=v_user and wallet_type='user' for update;
     if v_treasury.id is null or v_wallet.id is null or v_treasury.balance<v_amount then raise exception 'Treasury or user wallet is unavailable'; end if;
     update public.empire_wallets set balance=balance-v_amount where id=v_treasury.id;
     update public.empire_wallets set balance=balance+v_amount where id=v_wallet.id;
     insert into public.empire_transactions(from_wallet_id,to_wallet_id,amount,transaction_type,description,external_reference,created_by)
     values(v_treasury.id,v_wallet.id,v_amount,'reward','Verified email signup reward','signup:'||v_user::text,v_user);
     update public.empire_reward_events set transaction_id=(select id from public.empire_transactions where external_reference='signup:'||v_user::text) where id=v_event;
   end if;
 end if;
 v_code:=upper(trim(coalesce(v_meta->>'referral_code','')));
 if v_code<>'' then
   select user_id into v_referrer from public.empire_referral_codes where code=v_code;
   if v_referrer is not null and v_referrer<>v_user then
     insert into public.empire_referrals(referrer_user_id,referred_user_id,referral_code)
     values(v_referrer,v_user,v_code) on conflict(referred_user_id) do nothing;
   end if;
 end if;
 return jsonb_build_object('success',true,'signup_rewarded',v_event is not null);
end;
$$;
revoke all on function public.claim_empire_signup_reward() from public,anon;
grant execute on function public.claim_empire_signup_reward() to authenticated;

create or replace function public.pay_empire_referral_reward()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_ref public.empire_referrals%rowtype; v_amount numeric(30,8); v_enabled boolean; v_is_vip boolean;
 v_treasury public.empire_wallets%rowtype; v_wallet public.empire_wallets%rowtype; v_event uuid; v_key text;
begin
 if new.status<>'confirmed' or new.usd_amount<2 then return new; end if;
 select * into v_ref from public.empire_referrals where referred_user_id=new.user_id and status='pending' for update;
 if not found then return new; end if;
 select is_enabled into v_enabled from public.empire_reward_settings where setting_key='referral_reward_regular';
 if not coalesce(v_enabled,false) then return new; end if;
 select exists(select 1 from public.vip_memberships where user_id=v_ref.referrer_user_id and lower(status)='active' and expires_at>now()) into v_is_vip;
 select setting_value into v_amount from public.empire_reward_settings where setting_key=case when v_is_vip then 'referral_reward_vip' else 'referral_reward_regular' end;
 if coalesce(v_amount,0)<=0 then return new; end if;
 v_key:='referral:'||v_ref.id::text;
 insert into public.empire_reward_events(event_key,recipient_user_id,source_user_id,reward_type,amount)
 values(v_key,v_ref.referrer_user_id,v_ref.referred_user_id,'referral',v_amount)
 on conflict(event_key) do nothing returning id into v_event;
 if v_event is null then return new; end if;
 select * into v_treasury from public.empire_wallets where wallet_type='treasury' and user_id is null for update;
 select * into v_wallet from public.empire_wallets where user_id=v_ref.referrer_user_id and wallet_type='user' for update;
 if v_treasury.id is null or v_wallet.id is null or v_treasury.balance<v_amount then
   delete from public.empire_reward_events where id=v_event;
   return new;
 end if;
 update public.empire_wallets set balance=balance-v_amount where id=v_treasury.id;
 update public.empire_wallets set balance=balance+v_amount where id=v_wallet.id;
 insert into public.empire_transactions(from_wallet_id,to_wallet_id,amount,transaction_type,description,external_reference,created_by)
 values(v_treasury.id,v_wallet.id,v_amount,'referral_reward','Referral reward after verified purchase of at least $2 EMPC','referral:'||v_ref.id::text,new.user_id);
 update public.empire_reward_events set transaction_id=(select id from public.empire_transactions where external_reference=v_key) where id=v_event;
 update public.empire_referrals set status='paid',reward_amount=v_amount,paid_at=now() where id=v_ref.id;
 return new;
end;
$$;
drop trigger if exists empire_purchase_referral_reward on public.empirecoin_purchase_orders;
create trigger empire_purchase_referral_reward after update of status on public.empirecoin_purchase_orders
for each row when (new.status='confirmed' and old.status is distinct from new.status)
execute function public.pay_empire_referral_reward();

comment on table public.empire_reward_settings is 'Admin-managed internal EMPC reward amounts and switches; all payouts transfer from the internal treasury wallet.';
