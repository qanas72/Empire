-- EMPIRE unified feed, permanent video likes, five-like rewards and admin inbox
-- Run this script in Supabase SQL Editor after the existing publishing, wallet,
-- reward, VIP payment and notifications setup scripts.

-- Public thumbnails are kept separate from private video files.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('video-thumbnails','video-thumbnails',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists "Public can view video thumbnails" on storage.objects;
create policy "Public can view video thumbnails" on storage.objects
for select using (bucket_id='video-thumbnails');

drop policy if exists "Users upload own video thumbnails" on storage.objects;
create policy "Users upload own video thumbnails" on storage.objects
for insert to authenticated with check (
 bucket_id='video-thumbnails' and (storage.foldername(name))[1]=auth.uid()::text
);

drop policy if exists "Users delete own video thumbnails" on storage.objects;
create policy "Users delete own video thumbnails" on storage.objects
for delete to authenticated using (
 bucket_id='video-thumbnails' and (storage.foldername(name))[1]=auth.uid()::text
);

-- Keep the reward setting editable from the existing admin rewards panel.
insert into public.empire_reward_settings(setting_key,setting_value,is_enabled)
values('post_like_reward',1,true)
on conflict(setting_key) do nothing;

-- The reward event type already supports video_like in the reactions migration.
alter table public.empire_reward_events drop constraint if exists empire_reward_events_reward_type_check;
alter table public.empire_reward_events add constraint empire_reward_events_reward_type_check
 check(reward_type in ('post_like','video_like','signup','referral'));

-- Make sure both reaction stores exist.
create table if not exists public.community_post_reactions (
 post_id uuid not null references public.community_posts(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 reaction text not null check(reaction in ('like','dislike')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 primary key(post_id,user_id)
);
create table if not exists public.video_reactions (
 video_id uuid not null references public.videos(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 reaction text not null check(reaction in ('like','dislike')),
 created_at timestamptz not null default now(),
 primary key(video_id,user_id)
);
create index if not exists community_post_reactions_post_idx on public.community_post_reactions(post_id,reaction);
create index if not exists video_reactions_video_idx on public.video_reactions(video_id,reaction);
alter table public.community_post_reactions enable row level security;
alter table public.video_reactions enable row level security;
drop policy if exists "Public can read post reaction counts" on public.community_post_reactions;
create policy "Public can read post reaction counts" on public.community_post_reactions for select using(true);
drop policy if exists "Public can read video reaction counts" on public.video_reactions;
create policy "Public can read video reaction counts" on public.video_reactions for select using(true);
revoke all on public.community_post_reactions,public.video_reactions from public,anon,authenticated;
grant select on public.community_post_reactions,public.video_reactions to anon,authenticated;

-- Pay 1 configured EMPC for every complete group of five likes on each publication.
-- Parent-row locking in the RPC functions serializes simultaneous likes.
create or replace function public.pay_empire_like_milestone(
 p_publication_type text,p_publication_id uuid,p_author_id uuid,p_like_count integer,p_actor_id uuid
) returns boolean
language plpgsql security definer set search_path=public,pg_temp
as $$
declare
 v_amount numeric(30,8); v_enabled boolean; v_key text; v_event uuid;
 v_treasury public.empire_wallets%rowtype; v_wallet public.empire_wallets%rowtype; v_tx uuid;
begin
 if p_publication_type not in ('post','video') or p_like_count<5 or mod(p_like_count,5)<>0 then return false; end if;
 select setting_value,is_enabled into v_amount,v_enabled
 from public.empire_reward_settings where setting_key='post_like_reward';
 if not coalesce(v_enabled,false) or coalesce(v_amount,0)<=0 then return false; end if;
 v_key:='like-milestone:'||p_publication_type||':'||p_publication_id::text||':'||p_like_count::text;
 insert into public.empire_reward_events(event_key,recipient_user_id,source_user_id,reward_type,amount)
 values(v_key,p_author_id,p_actor_id,case when p_publication_type='video' then 'video_like' else 'post_like' end,v_amount)
 on conflict(event_key) do nothing returning id into v_event;
 if v_event is null then return false; end if;

 select * into v_treasury from public.empire_wallets
 where wallet_type='treasury' and user_id is null for update;
 select * into v_wallet from public.empire_wallets
 where wallet_type='user' and user_id=p_author_id for update;
 if v_treasury.id is null or v_wallet.id is null or v_treasury.balance<v_amount then
   raise exception 'The EMPIRE Treasury does not currently have enough EMPC to pay this like milestone. Please contact support.';
 end if;

 update public.empire_wallets set balance=balance-v_amount where id=v_treasury.id;
 update public.empire_wallets set balance=balance+v_amount where id=v_wallet.id;
 insert into public.empire_transactions(from_wallet_id,to_wallet_id,amount,transaction_type,description,external_reference,created_by)
 values(v_treasury.id,v_wallet.id,v_amount,'reward',
   'EMPC reward for reaching '||p_like_count||' likes on an EMPIRE '||p_publication_type,
   v_key,p_actor_id) returning id into v_tx;
 update public.empire_reward_events set transaction_id=v_tx where id=v_event;
 return true;
end;
$$;
revoke all on function public.pay_empire_like_milestone(text,uuid,uuid,integer,uuid) from public,anon,authenticated;

-- Permanent post reaction: one reaction per account and publication; no removal or switching.
create or replace function public.toggle_community_post_reaction(p_post_id uuid,p_reaction text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare
 v_user uuid:=auth.uid(); v_author uuid; v_likes integer; v_dislikes integer; v_rewarded boolean:=false;
begin
 if v_user is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from auth.users where id=v_user and email_confirmed_at is not null) then raise exception 'Confirm your email before reacting'; end if;
 if not exists(select 1 from public.profiles where id=v_user and is_active=true) then raise exception 'Active account required'; end if;
 if p_reaction not in ('like','dislike') then raise exception 'Invalid reaction'; end if;
 select author_id into v_author from public.community_posts where id=p_post_id and is_removed=false for update;
 if not found then raise exception 'Publication not found'; end if;
 if v_author=v_user then raise exception 'You cannot react to your own publication'; end if;
 insert into public.community_post_reactions(post_id,user_id,reaction)
 values(p_post_id,v_user,p_reaction) on conflict(post_id,user_id) do nothing;
 if not found then raise exception 'You have already reacted to this publication. Reactions cannot be removed or changed.'; end if;
 select count(*) filter(where reaction='like'),count(*) filter(where reaction='dislike')
 into v_likes,v_dislikes from public.community_post_reactions where post_id=p_post_id;
 if p_reaction='like' and mod(v_likes,5)=0 then
   v_rewarded:=public.pay_empire_like_milestone('post',p_post_id,v_author,v_likes,v_user);
 end if;
 return jsonb_build_object('like_count',coalesce(v_likes,0),'dislike_count',coalesce(v_dislikes,0),
   'my_reaction',p_reaction,'rewarded',v_rewarded,'reward_milestone',case when v_rewarded then v_likes else null end);
end;
$$;
revoke all on function public.toggle_community_post_reaction(uuid,text) from public,anon;
grant execute on function public.toggle_community_post_reaction(uuid,text) to authenticated;

-- Permanent video reaction: one reaction per account and approved video.
create or replace function public.react_to_empire_video(p_video_id uuid,p_reaction text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp
as $$
declare
 v_user uuid:=auth.uid(); v_author uuid; v_likes integer; v_dislikes integer; v_rewarded boolean:=false;
begin
 if v_user is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from auth.users where id=v_user and email_confirmed_at is not null) then raise exception 'Confirm your email before reacting'; end if;
 if not exists(select 1 from public.profiles where id=v_user and is_active=true) then raise exception 'Active account required'; end if;
 if p_reaction not in ('like','dislike') then raise exception 'Invalid reaction'; end if;
 select creator_id into v_author from public.videos where id=p_video_id and approval_status='approved' for update;
 if not found then raise exception 'Video not found or not approved'; end if;
 if v_author=v_user then raise exception 'You cannot react to your own video'; end if;
 insert into public.video_reactions(video_id,user_id,reaction)
 values(p_video_id,v_user,p_reaction) on conflict(video_id,user_id) do nothing;
 if not found then raise exception 'You have already reacted to this video. Reactions cannot be removed or changed.'; end if;
 select count(*) filter(where reaction='like'),count(*) filter(where reaction='dislike')
 into v_likes,v_dislikes from public.video_reactions where video_id=p_video_id;
 if p_reaction='like' and mod(v_likes,5)=0 then
   v_rewarded:=public.pay_empire_like_milestone('video',p_video_id,v_author,v_likes,v_user);
 end if;
 return jsonb_build_object('like_count',coalesce(v_likes,0),'dislike_count',coalesce(v_dislikes,0),
   'my_reaction',p_reaction,'rewarded',v_rewarded,'reward_milestone',case when v_rewarded then v_likes else null end);
end;
$$;
revoke all on function public.react_to_empire_video(uuid,text) from public,anon;
grant execute on function public.react_to_empire_video(uuid,text) to authenticated;

-- Send admin inbox entries to the two verified EMPIRE administrator accounts only.
create or replace function public.notify_empire_admins(
 p_type text,p_title text,p_body text,p_url text,p_source_id text
) returns void language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 perform public.create_empire_notification('8166f8a9-fdc3-43a4-85c7-53ec1dbbde0e'::uuid,p_type,p_title,p_body,p_url,p_source_id);
 perform public.create_empire_notification('7c5f5c13-b106-4c7c-9bd5-9339576bfe7a'::uuid,p_type,p_title,p_body,p_url,p_source_id);
end;
$$;
revoke all on function public.notify_empire_admins(text,text,text,text,text) from public,anon,authenticated;

create or replace function public.notify_admin_new_video_submission()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 if coalesce(new.approval_status,'pending')='pending' then
  perform public.notify_empire_admins('admin_video_pending','New video awaiting review',
   coalesce(new.title,'A user submitted a video')||' is waiting for administrator approval.',
   'admin.html?view=videos','video:'||new.id::text);
 end if;
 return new;
end;
$$;
drop trigger if exists empire_admin_notify_video_submission on public.videos;
create trigger empire_admin_notify_video_submission after insert on public.videos
for each row execute function public.notify_admin_new_video_submission();

create or replace function public.notify_admin_new_vip_request()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 if coalesce(new.status,'pending')='pending' then
  perform public.notify_empire_admins('admin_vip_request','New VIP payment request',
   'A user submitted a VIP plan payment request: '||coalesce(new.plan,'VIP plan')||' · '||
   coalesce(new.amount::text,'')||' '||coalesce(new.currency,''),
   'vip-admin.html','vip-request:'||new.id::text);
 end if;
 return new;
end;
$$;
drop trigger if exists empire_admin_notify_vip_request on public.vip_payment_requests;
create trigger empire_admin_notify_vip_request after insert on public.vip_payment_requests
for each row execute function public.notify_admin_new_vip_request();

create or replace function public.notify_admin_new_support_request()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 perform public.notify_empire_admins('admin_support_request','New Support request',
  coalesce(new.subject,'Support request')||' — '||left(coalesce(new.message,''),180),
  'admin-support.html','support-request:'||new.id::text);
 return new;
end;
$$;
drop trigger if exists empire_admin_notify_support_request on public.support_requests;
create trigger empire_admin_notify_support_request after insert on public.support_requests
for each row execute function public.notify_admin_new_support_request();

create or replace function public.notify_admin_new_post_report()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 perform public.notify_empire_admins('admin_post_report','New publication report',
  left(coalesce(new.reason,'A publication was reported'),180),
  'publishing-admin.html','post-report:'||new.id::text);
 return new;
end;
$$;
drop trigger if exists empire_admin_notify_post_report on public.post_reports;
create trigger empire_admin_notify_post_report after insert on public.post_reports
for each row execute function public.notify_admin_new_post_report();

create or replace function public.notify_admin_new_community_post()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 perform public.notify_empire_admins('admin_new_publication','New community publication',
  left(coalesce(new.content,'A user published an image'),180),
  'publishing-admin.html','community-post:'||new.id::text);
 return new;
end;
$$;
drop trigger if exists empire_admin_notify_community_post on public.community_posts;
create trigger empire_admin_notify_community_post after insert on public.community_posts
for each row execute function public.notify_admin_new_community_post();

-- Notify users when a submitted video is approved or rejected.
create or replace function public.notify_user_video_review_result()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 if new.approval_status is distinct from old.approval_status
    and new.approval_status in ('approved','rejected') then
  perform public.create_empire_notification(new.creator_id,'video_review',
   case when new.approval_status='approved' then 'Your video was approved' else 'Your video was not approved' end,
   coalesce(new.title,'Your video')||
    case when new.approval_status='approved' then ' is now published on EMPIRE.' else ' was rejected.' end||
    case when coalesce(new.rejection_reason,'')<>'' then ' Reason: '||new.rejection_reason else '' end,
   'index.html#community','video-review:'||new.id::text||':'||new.approval_status);
 end if;
 return new;
end;
$$;
drop trigger if exists empire_user_notify_video_review on public.videos;
create trigger empire_user_notify_video_review after update of approval_status on public.videos
for each row execute function public.notify_user_video_review_result();

-- Notify users when VIP payment requests are reviewed.
create or replace function public.notify_user_vip_review_result()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 if new.status is distinct from old.status and new.status in ('confirmed','rejected','approved','paid') then
  perform public.create_empire_notification(new.user_id,'vip_request_update',
   case when new.status in ('confirmed','approved','paid') then 'Your VIP request was approved' else 'Your VIP request was rejected' end,
   'Your VIP payment request for '||coalesce(new.plan,'VIP plan')||' has been marked '||new.status||'.',
   'premium.html','vip-review:'||new.id::text||':'||new.status);
 end if;
 return new;
end;
$$;
drop trigger if exists empire_user_notify_vip_review on public.vip_payment_requests;
create trigger empire_user_notify_vip_review after update of status on public.vip_payment_requests
for each row execute function public.notify_user_vip_review_result();
