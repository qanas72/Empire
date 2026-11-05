-- EMPIRE permanent reactions, VIP controls and managed raffles
-- Run in Supabase SQL Editor after empire-engagement-rewards-setup.sql.

-- 1) Reactions are permanent: a user may react once per publication.
create or replace function public.toggle_community_post_reaction(p_post_id uuid,p_reaction text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare
 v_user uuid:=auth.uid(); v_author uuid; v_like_count integer; v_dislike_count integer;
 v_amount numeric(30,8); v_enabled boolean; v_treasury public.empire_wallets%rowtype;
 v_wallet public.empire_wallets%rowtype; v_event uuid; v_rewarded boolean:=false;
begin
 if v_user is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from auth.users where id=v_user and email_confirmed_at is not null) then raise exception 'Confirm your email before reacting'; end if;
 if not exists(select 1 from public.profiles where id=v_user and is_active=true) then raise exception 'Active account required'; end if;
 if p_reaction not in ('like','dislike') then raise exception 'Invalid reaction'; end if;
 select author_id into v_author from public.community_posts where id=p_post_id and is_removed=false;
 if not found then raise exception 'Publication not found'; end if;
 if v_author=v_user then raise exception 'You cannot react to your own publication'; end if;
 -- Unique key permanently blocks both repeat clicks and switching reaction type.
 insert into public.community_post_reactions(post_id,user_id,reaction)
 values(p_post_id,v_user,p_reaction)
 on conflict(post_id,user_id) do nothing;
 if not found then raise exception 'You have already reacted to this publication. Reactions cannot be removed or changed.'; end if;

 if p_reaction='like' then
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
         update public.empire_reward_events set transaction_id=(select id from public.empire_transactions where external_reference='post-like:'||p_post_id::text||':'||v_user::text) where id=v_event;
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
   'my_reaction',p_reaction,'rewarded',v_rewarded);
end;
$$;
revoke all on function public.toggle_community_post_reaction(uuid,text) from public,anon;
grant execute on function public.toggle_community_post_reaction(uuid,text) to authenticated;

-- 2) Video reactions and rewards, one permanent reaction per user/video.
alter table public.empire_reward_events drop constraint if exists empire_reward_events_reward_type_check;
alter table public.empire_reward_events add constraint empire_reward_events_reward_type_check
 check(reward_type in ('post_like','video_like','signup','referral'));

create table if not exists public.video_reactions (
 video_id uuid not null references public.videos(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 reaction text not null check(reaction in ('like','dislike')),
 created_at timestamptz not null default now(),
 primary key(video_id,user_id)
);
create index if not exists video_reactions_video_idx on public.video_reactions(video_id,reaction);
alter table public.video_reactions enable row level security;
drop policy if exists "Public can read video reaction counts" on public.video_reactions;
create policy "Public can read video reaction counts" on public.video_reactions for select using(true);
revoke all on public.video_reactions from public,anon,authenticated;
grant select on public.video_reactions to anon,authenticated;

create or replace function public.react_to_empire_video(p_video_id uuid,p_reaction text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare
 v_user uuid:=auth.uid(); v_author uuid; v_likes integer; v_dislikes integer;
 v_amount numeric(30,8); v_enabled boolean; v_treasury public.empire_wallets%rowtype;
 v_wallet public.empire_wallets%rowtype; v_event uuid; v_rewarded boolean:=false; v_key text;
begin
 if v_user is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from auth.users where id=v_user and email_confirmed_at is not null) then raise exception 'Confirm your email before reacting'; end if;
 if not exists(select 1 from public.profiles where id=v_user and is_active=true) then raise exception 'Active account required'; end if;
 if p_reaction not in ('like','dislike') then raise exception 'Invalid reaction'; end if;
 select creator_id into v_author from public.videos where id=p_video_id and approval_status='approved';
 if not found then raise exception 'Video not found or not approved'; end if;
 if v_author=v_user then raise exception 'You cannot react to your own video'; end if;
 insert into public.video_reactions(video_id,user_id,reaction) values(p_video_id,v_user,p_reaction)
 on conflict(video_id,user_id) do nothing;
 if not found then raise exception 'You have already reacted to this video. Reactions cannot be removed or changed.'; end if;
 if p_reaction='like' then
  select setting_value,is_enabled into v_amount,v_enabled from public.empire_reward_settings where setting_key='post_like_reward';
  v_key:='video-like:'||p_video_id::text||':'||v_user::text;
  if coalesce(v_enabled,false) and coalesce(v_amount,0)>0 then
   insert into public.empire_reward_events(event_key,recipient_user_id,source_user_id,reward_type,amount)
   values(v_key,v_author,v_user,'video_like',v_amount) on conflict(event_key) do nothing returning id into v_event;
   if v_event is not null then
    select * into v_treasury from public.empire_wallets where wallet_type='treasury' and user_id is null for update;
    select * into v_wallet from public.empire_wallets where user_id=v_author and wallet_type='user' for update;
    if v_treasury.id is not null and v_wallet.id is not null and v_treasury.balance>=v_amount then
     update public.empire_wallets set balance=balance-v_amount where id=v_treasury.id;
     update public.empire_wallets set balance=balance+v_amount where id=v_wallet.id;
     insert into public.empire_transactions(from_wallet_id,to_wallet_id,amount,transaction_type,description,external_reference,created_by)
     values(v_treasury.id,v_wallet.id,v_amount,'reward','EMPC reward for receiving a video like',v_key,v_user);
     update public.empire_reward_events set transaction_id=(select id from public.empire_transactions where external_reference=v_key) where id=v_event;
     v_rewarded:=true;
    else delete from public.empire_reward_events where id=v_event;
    end if;
   end if;
  end if;
 end if;
 select count(*) filter(where reaction='like'),count(*) filter(where reaction='dislike')
 into v_likes,v_dislikes from public.video_reactions where video_id=p_video_id;
 return jsonb_build_object('like_count',coalesce(v_likes,0),'dislike_count',coalesce(v_dislikes,0),'my_reaction',p_reaction,'rewarded',v_rewarded);
end;
$$;
revoke all on function public.react_to_empire_video(uuid,text) from public,anon;
grant execute on function public.react_to_empire_video(uuid,text) to authenticated;

-- 3) Admin-editable VIP prices and secure complimentary VIP grants.
create table if not exists public.empire_vip_plan_settings(
 plan_key text primary key,
 plan_name text not null,
 duration_days integer not null check(duration_days between 1 and 730),
 price_usd numeric(12,2) not null check(price_usd>=0),
 is_enabled boolean not null default true,
 updated_by uuid references auth.users(id),
 updated_at timestamptz not null default now()
);
insert into public.empire_vip_plan_settings(plan_key,plan_name,duration_days,price_usd) values
 ('vip-monthly','1 Month VIP',30,9),
 ('vip-quarterly','3 Months VIP',90,21),
 ('vip-semiannual','6 Months VIP',180,49),
 ('vip-yearly','1 Year VIP',365,89)
on conflict(plan_key) do nothing;
alter table public.empire_vip_plan_settings enable row level security;
drop policy if exists "Public can read enabled VIP plans" on public.empire_vip_plan_settings;
create policy "Public can read enabled VIP plans" on public.empire_vip_plan_settings for select using(is_enabled or public.is_admin());
revoke all on public.empire_vip_plan_settings from public,anon,authenticated;
grant select on public.empire_vip_plan_settings to anon,authenticated;

create table if not exists public.empire_vip_admin_logs(
 id uuid primary key default gen_random_uuid(),
 target_user_id uuid not null references auth.users(id),
 plan_key text not null,
 action text not null,
 admin_user_id uuid references auth.users(id),
 created_at timestamptz not null default now()
);
alter table public.empire_vip_admin_logs enable row level security;
drop policy if exists "Admins read VIP admin logs" on public.empire_vip_admin_logs;
create policy "Admins read VIP admin logs" on public.empire_vip_admin_logs for select to authenticated using(public.is_admin());
revoke all on public.empire_vip_admin_logs from public,anon,authenticated;
grant select on public.empire_vip_admin_logs to authenticated;

create or replace function public.admin_update_empire_vip_plan(p_plan_key text,p_price_usd numeric,p_enabled boolean)
returns void language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_price_usd is null or p_price_usd<0 or p_price_usd>100000 then raise exception 'Invalid VIP price'; end if;
 update public.empire_vip_plan_settings set price_usd=p_price_usd,is_enabled=p_enabled,updated_by=auth.uid(),updated_at=now()
 where plan_key=p_plan_key;
 if not found then raise exception 'VIP plan not found'; end if;
end;
$$;
revoke all on function public.admin_update_empire_vip_plan(text,numeric,boolean) from public,anon;
grant execute on function public.admin_update_empire_vip_plan(text,numeric,boolean) to authenticated;

create or replace function public.admin_gift_empire_vip(p_user_id uuid,p_plan_key text)
returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_plan public.empire_vip_plan_settings%rowtype; v_start timestamptz; v_expiry timestamptz; v_id uuid;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_user_id is null or not exists(select 1 from auth.users where id=p_user_id) then raise exception 'User not found'; end if;
 select * into v_plan from public.empire_vip_plan_settings where plan_key=p_plan_key;
 if not found then raise exception 'VIP plan not found'; end if;
 v_start:=now();
 select greatest(now(),max(expires_at)) into v_start from public.vip_memberships
 where user_id=p_user_id and status='active' and expires_at>now();
 v_start:=coalesce(v_start,now());
 v_expiry:=v_start+make_interval(days=>v_plan.duration_days);
 insert into public.vip_memberships(user_id,plan,status,starts_at,expires_at)
 values(p_user_id,p_plan_key,'active',v_start,v_expiry)
 returning id into v_id;
 insert into public.empire_vip_admin_logs(target_user_id,plan_key,action,admin_user_id)
 values(p_user_id,p_plan_key,'gifted',auth.uid());
 return v_id;
end;
$$;
revoke all on function public.admin_gift_empire_vip(uuid,text) from public,anon;
grant execute on function public.admin_gift_empire_vip(uuid,text) to authenticated;

-- 4) Admin-managed raffle campaigns. Entries require >=$5 confirmed EMPC purchases
-- AND a current wallet balance >= $5 at the current configured EMPC reference price.
create table if not exists public.empire_raffles(
 id uuid primary key default gen_random_uuid(),
 title text not null,
 description text not null default '',
 conditions text not null default '',
 prize_1 text not null,
 prize_2 text not null,
 prize_3 text not null,
 status text not null default 'draft' check(status in ('draft','open','completed','cancelled')),
 target_participants integer not null default 50 check(target_participants between 3 and 5000),
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 opened_at timestamptz,
 completed_at timestamptz
);
create table if not exists public.empire_raffle_entries(
 id uuid primary key default gen_random_uuid(),
 raffle_id uuid not null references public.empire_raffles(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now(),
 unique(raffle_id,user_id)
);
create table if not exists public.empire_raffle_winners(
 id uuid primary key default gen_random_uuid(),
 raffle_id uuid not null references public.empire_raffles(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 prize_rank integer not null check(prize_rank between 1 and 3),
 prize_description text not null,
 selected_at timestamptz not null default now(),
 unique(raffle_id,prize_rank),
 unique(raffle_id,user_id)
);
alter table public.empire_raffles enable row level security;
alter table public.empire_raffle_entries enable row level security;
alter table public.empire_raffle_winners enable row level security;
drop policy if exists "Public read open and completed raffles" on public.empire_raffles;
create policy "Public read open and completed raffles" on public.empire_raffles for select using(status in ('open','completed') or public.is_admin());
drop policy if exists "Users read raffle participant totals" on public.empire_raffle_entries;
create policy "Admins read raffle entries" on public.empire_raffle_entries for select to authenticated using(public.is_admin());
drop policy if exists "Public read raffle winners" on public.empire_raffle_winners;
create policy "Public read raffle winners" on public.empire_raffle_winners for select using(true);
revoke all on public.empire_raffles,public.empire_raffle_entries,public.empire_raffle_winners from public,anon,authenticated;
grant select on public.empire_raffles,public.empire_raffle_entries,public.empire_raffle_winners to anon,authenticated;


create or replace function public.get_empire_raffle_public_data(p_raffle_ids uuid[])
returns table(raffle_id uuid,participant_count bigint,joined_by_me boolean)
language sql stable security definer set search_path=public,pg_temp
as $$
 select r.id,count(e.id),coalesce(bool_or(e.user_id=auth.uid()),false)
 from public.empire_raffles r
 left join public.empire_raffle_entries e on e.raffle_id=r.id
 where r.id=any(coalesce(p_raffle_ids,'{}'::uuid[])) and r.status in ('open','completed')
 group by r.id
$;
revoke all on function public.get_empire_raffle_public_data(uuid[]) from public;
grant execute on function public.get_empire_raffle_public_data(uuid[]) to anon,authenticated;

create or replace function public.admin_save_empire_raffle(
 p_raffle_id uuid,p_title text,p_description text,p_conditions text,
 p_prize_1 text,p_prize_2 text,p_prize_3 text,p_action text
) returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_id uuid;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if length(trim(coalesce(p_title,'')))<3 or length(trim(coalesce(p_prize_1,'')))<2 or length(trim(coalesce(p_prize_2,'')))<2 or length(trim(coalesce(p_prize_3,'')))<2 then raise exception 'Title and all three prizes are required'; end if;
 if p_action='create' then
  insert into public.empire_raffles(title,description,conditions,prize_1,prize_2,prize_3,created_by)
  values(trim(p_title),coalesce(p_description,''),coalesce(p_conditions,''),trim(p_prize_1),trim(p_prize_2),trim(p_prize_3),auth.uid())
  returning id into v_id;
 elsif p_action='update' then
  update public.empire_raffles set title=trim(p_title),description=coalesce(p_description,''),conditions=coalesce(p_conditions,''),
   prize_1=trim(p_prize_1),prize_2=trim(p_prize_2),prize_3=trim(p_prize_3)
  where id=p_raffle_id and status='draft' returning id into v_id;
  if v_id is null then raise exception 'Only draft raffles can be edited'; end if;
 else raise exception 'Invalid raffle action'; end if;
 return v_id;
end;
$$;
revoke all on function public.admin_save_empire_raffle(uuid,text,text,text,text,text,text,text) from public,anon;
grant execute on function public.admin_save_empire_raffle(uuid,text,text,text,text,text,text,text) to authenticated;

create or replace function public.admin_set_empire_raffle_status(p_raffle_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 if p_status not in ('open','cancelled') then raise exception 'Invalid raffle status'; end if;
 update public.empire_raffles set status=p_status,opened_at=case when p_status='open' then now() else opened_at end
 where id=p_raffle_id and status='draft';
 if not found then raise exception 'Only a draft raffle can be opened or cancelled'; end if;
end;
$$;
revoke all on function public.admin_set_empire_raffle_status(uuid,text) from public,anon;
grant execute on function public.admin_set_empire_raffle_status(uuid,text) to authenticated;

create or replace function public.join_empire_raffle(p_raffle_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_user uuid:=auth.uid(); v_price numeric; v_min_balance numeric; v_balance numeric; v_purchased numeric; v_entry uuid; v_count integer; v_raffle public.empire_raffles%rowtype; v_row record;
begin
 if v_user is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from auth.users where id=v_user and email_confirmed_at is not null) then raise exception 'Confirm your email first'; end if;
 select * into v_raffle from public.empire_raffles where id=p_raffle_id for update;
 if not found or v_raffle.status<>'open' then raise exception 'This raffle is not open'; end if;
 select setting_value into v_price from public.empire_economic_settings where setting_key='empc_usd_price';
 if coalesce(v_price,0)<=0 then raise exception 'Current EMPC reference price is unavailable'; end if;
 v_min_balance:=5/v_price;
 select balance into v_balance from public.empire_wallets where user_id=v_user and wallet_type='user';
 select coalesce(sum(usd_amount),0) into v_purchased from public.empirecoin_purchase_orders where user_id=v_user and status='confirmed';
 if coalesce(v_purchased,0)<5 then raise exception 'You must have confirmed EMPC purchases of at least $5'; end if;
 if coalesce(v_balance,0)<v_min_balance then raise exception 'Your current wallet balance must be at least the EMPC equivalent of $5'; end if;
 insert into public.empire_raffle_entries(raffle_id,user_id) values(p_raffle_id,v_user)
 on conflict(raffle_id,user_id) do nothing returning id into v_entry;
 if v_entry is null then raise exception 'You have already joined this raffle'; end if;
 select count(*) into v_count from public.empire_raffle_entries where raffle_id=p_raffle_id;
 if v_count>=v_raffle.target_participants then
   for v_row in
    select picked.user_id, row_number() over(order by random()) as rank
    from (
      select e.user_id from public.empire_raffle_entries e
      where e.raffle_id=p_raffle_id order by random() limit 3
    ) picked
   loop
    insert into public.empire_raffle_winners(raffle_id,user_id,prize_rank,prize_description)
    values(p_raffle_id,v_row.user_id,v_row.rank,
      case v_row.rank when 1 then v_raffle.prize_1 when 2 then v_raffle.prize_2 else v_raffle.prize_3 end);
   end loop;
   update public.empire_raffles set status='completed',completed_at=now() where id=p_raffle_id;
 end if;
 return jsonb_build_object('success',true,'participant_count',v_count,'target_participants',v_raffle.target_participants,'draw_completed',v_count>=v_raffle.target_participants);
end;
$$;
revoke all on function public.join_empire_raffle(uuid) from public,anon;
grant execute on function public.join_empire_raffle(uuid) to authenticated;

comment on table public.empire_raffles is 'Admin-managed EMPIRE raffles; winners are selected randomly when the participant target is reached.';
