-- EMPIRE Notifications Center
create table if not exists public.empire_notifications (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 notification_type text not null,
 title text not null,
 body text not null default '',
 target_url text not null default 'notifications.html',
 source_id text,
 created_at timestamptz not null default now(),
 read_at timestamptz,
 unique(user_id,notification_type,source_id)
);
create index if not exists empire_notifications_user_unread_idx
 on public.empire_notifications(user_id,created_at desc) where read_at is null;
create index if not exists empire_notifications_user_created_idx
 on public.empire_notifications(user_id,created_at desc);
alter table public.empire_notifications enable row level security;
drop policy if exists "Users read own EMPIRE notifications" on public.empire_notifications;
create policy "Users read own EMPIRE notifications"
 on public.empire_notifications for select to authenticated using(user_id=auth.uid());
drop policy if exists "Users mark own EMPIRE notifications read" on public.empire_notifications;
create policy "Users mark own EMPIRE notifications read"
 on public.empire_notifications for update to authenticated
 using(user_id=auth.uid()) with check(user_id=auth.uid());
revoke all on public.empire_notifications from anon,public;
grant select,update on public.empire_notifications to authenticated;

create or replace function public.create_empire_notification(
 p_user_id uuid,p_type text,p_title text,p_body text,p_url text,p_source_id text
) returns void language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 if p_user_id is null then return; end if;
 insert into public.empire_notifications(user_id,notification_type,title,body,target_url,source_id)
 values(p_user_id,p_type,left(coalesce(p_title,'EMPIRE Notification'),160),left(coalesce(p_body,''),1000),
        coalesce(nullif(p_url,''),'notifications.html'),p_source_id)
 on conflict(user_id,notification_type,source_id) do nothing;
end;
$$;
revoke all on function public.create_empire_notification(uuid,text,text,text,text,text) from public,anon,authenticated;

create or replace function public.notify_empire_new_message()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_sender text;
begin
 select coalesce(nullif(p.username,''),nullif(p.display_name,''),'An EMPIRE member')
 into v_sender from public.profiles p where p.id=new.sender_id;
 perform public.create_empire_notification(new.receiver_id,'new_message','New message from '||coalesce(v_sender,'an EMPIRE member'),
  case when coalesce(new.content,'')='' then 'You received a new message.' else left(new.content,180) end,
  'messages.html?user_id='||new.sender_id::text,new.id::text);
 return new;
end; $$;
drop trigger if exists empire_notify_new_message on public.empire_messages;
create trigger empire_notify_new_message after insert on public.empire_messages
for each row execute function public.notify_empire_new_message();

create or replace function public.notify_empire_warning()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 perform public.create_empire_notification(new.user_id,'admin_warning','You received an official warning',
  new.message,'profile.html',new.id::text);
 return new;
end; $$;
drop trigger if exists empire_notify_warning on public.user_warnings;
create trigger empire_notify_warning after insert on public.user_warnings
for each row execute function public.notify_empire_warning();

create or replace function public.notify_empire_support_reply()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
begin
 if new.admin_reply is not null and length(trim(new.admin_reply))>0
    and (tg_op='INSERT' or old.admin_reply is distinct from new.admin_reply) then
  perform public.create_empire_notification(new.user_id,'support_reply','EMPIRE Support replied',
   left(new.admin_reply,180),'support.html#mySupportRequests',new.id::text||':'||md5(new.admin_reply));
 end if;
 return new;
end; $$;
drop trigger if exists empire_notify_support_reply on public.support_requests;
create trigger empire_notify_support_reply after insert or update of admin_reply on public.support_requests
for each row execute function public.notify_empire_support_reply();

create or replace function public.notify_empire_raffle_winner()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
declare v_title text;
begin
 select title into v_title from public.empire_raffles where id=new.raffle_id;
 perform public.create_empire_notification(new.user_id,'raffle_winner','Congratulations! You won an EMPIRE raffle',
  coalesce(v_title,'An EMPIRE raffle')||' — '||coalesce(new.prize_description,'You are a winner.'),
  'raffle.html','raffle-winner:'||new.id::text);
 return new;
end; $$;
drop trigger if exists empire_notify_raffle_winner on public.empire_raffle_winners;
create trigger empire_notify_raffle_winner after insert on public.empire_raffle_winners
for each row execute function public.notify_empire_raffle_winner();
