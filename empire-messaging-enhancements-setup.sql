-- EMPIRE private message enhancements: per-user hide, file attachments, stable media metadata.
alter table public.empire_messages
  add column if not exists hidden_by_sender boolean not null default false,
  add column if not exists hidden_by_receiver boolean not null default false,
  add column if not exists media_file_name text,
  add column if not exists media_mime_type text;

alter table public.empire_messages
  drop constraint if exists empire_messages_media_type_check;
alter table public.empire_messages
  add constraint empire_messages_media_type_check
  check (media_type is null or media_type in ('image','video','audio','file'));

drop policy if exists "Conversation participants can read messages" on public.empire_messages;
create policy "Participants can read messages visible to them"
on public.empire_messages for select to authenticated
using (
  (sender_id = auth.uid() and hidden_by_sender = false)
  or
  (receiver_id = auth.uid() and hidden_by_receiver = false)
);

create or replace function public.hide_empire_message_for_me(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_updated integer;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  update public.empire_messages
  set hidden_by_sender = case when sender_id = v_user_id then true else hidden_by_sender end,
      hidden_by_receiver = case when receiver_id = v_user_id then true else hidden_by_receiver end
  where id = p_message_id
    and (sender_id = v_user_id or receiver_id = v_user_id);
  get diagnostics v_updated = row_count;
  if v_updated = 0 then raise exception 'Message not found or access denied'; end if;
end;
$$;
revoke all on function public.hide_empire_message_for_me(uuid) from public, anon;
grant execute on function public.hide_empire_message_for_me(uuid) to authenticated;

-- Keep the private bucket and 50 MB limit; permit common and uncommon file MIME types.
update storage.buckets
set allowed_mime_types = null,
    file_size_limit = 52428800
where id = 'message-media';

create or replace function public.send_empire_media_message(
  p_receiver_id uuid,
  p_media_type text,
  p_media_path text,
  p_file_name text,
  p_mime_type text
)
returns table (message_id uuid, charged_amount numeric, remaining_balance numeric)
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $$
declare
  v_sender_id uuid := auth.uid();
  v_sender_wallet_id uuid;
  v_treasury_wallet_id uuid := '00000000-0000-0000-0000-000000000001'::uuid;
  v_balance numeric(30,8);
  v_fee numeric(30,8) := 3;
  v_message_id uuid;
  v_remaining numeric(30,8);
begin
  if v_sender_id is null then raise exception 'Authentication required'; end if;
  if p_receiver_id is null or p_receiver_id = v_sender_id then raise exception 'Invalid recipient'; end if;
  if p_media_type is null or p_media_type not in ('image','video','audio','file') then raise exception 'Unsupported media type'; end if;
  if p_media_path is null or (storage.foldername(p_media_path))[1] <> v_sender_id::text
     or not exists (select 1 from storage.objects so where so.bucket_id='message-media' and so.name=p_media_path and so.owner_id=v_sender_id::text)
  then raise exception 'Media upload not found or not owned by sender'; end if;
  if p_file_name is null or length(btrim(p_file_name))=0 or length(p_file_name)>255 then raise exception 'Invalid file name'; end if;
  if not exists (select 1 from public.profiles p where p.id=p_receiver_id and p.is_active=true) then raise exception 'Recipient not found or inactive'; end if;
  if not exists (select 1 from public.vip_memberships vm where vm.user_id=v_sender_id and vm.status='active' and vm.expires_at>now()) then
    raise exception 'Active VIP membership is required to send photos, videos, voice messages, or files';
  end if;

  select w.id,w.balance into v_sender_wallet_id,v_balance
  from public.empire_wallets w where w.user_id=v_sender_id and w.wallet_type='user' for update;
  if v_sender_wallet_id is null then raise exception 'EmpireCoin wallet not found'; end if;
  if v_balance<v_fee then raise exception 'Insufficient EMPC balance. Required: % EMPC',v_fee; end if;
  perform 1 from public.empire_wallets w where w.id=v_treasury_wallet_id and w.wallet_type='treasury' for update;
  if not found then raise exception 'EMPIRE treasury wallet not found'; end if;

  insert into public.empire_messages(sender_id,receiver_id,content,media_type,media_path,media_file_name,media_mime_type)
  values (
    v_sender_id,p_receiver_id,
    case p_media_type when 'image' then '[Photo]' when 'video' then '[Video]' when 'audio' then '[Voice message]' else '[File: '||p_file_name||']' end,
    p_media_type,p_media_path,left(p_file_name,255),left(coalesce(p_mime_type,'application/octet-stream'),255)
  ) returning id into v_message_id;

  update public.empire_wallets set balance=balance-v_fee where id=v_sender_wallet_id returning balance into v_remaining;
  update public.empire_wallets set balance=balance+v_fee where id=v_treasury_wallet_id;
  insert into public.empire_transactions(from_wallet_id,to_wallet_id,amount,transaction_type,description,external_reference,created_by)
  values(v_sender_wallet_id,v_treasury_wallet_id,v_fee,'message_fee','VIP media/file message fee','message:'||v_message_id::text,v_sender_id);
  return query select v_message_id,v_fee,v_remaining;
end;
$$;
revoke all on function public.send_empire_media_message(uuid,text,text,text,text) from public, anon;
grant execute on function public.send_empire_media_message(uuid,text,text,text,text) to authenticated;
