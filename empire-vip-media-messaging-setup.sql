-- EMPIRE VIP-only media messaging
-- Text messaging remains on the existing send_empire_message(uuid,text) RPC.
-- Media messages use a separate VIP-verified RPC and a private Storage bucket.

alter table public.empire_messages
  add column if not exists media_type text,
  add column if not exists media_path text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.empire_messages'::regclass
      and conname = 'empire_messages_media_type_check'
  ) then
    alter table public.empire_messages
      add constraint empire_messages_media_type_check
      check (media_type is null or media_type in ('image','video','audio'));
  end if;
end $$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'message-media',
  'message-media',
  false,
  52428800,
  array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime','audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav']
)
on conflict (id) do update
set public = false,
    file_size_limit = 52428800,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "VIP users can upload their own message media" on storage.objects;
create policy "VIP users can upload their own message media"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'message-media'
  and (storage.foldername(name))[1] = auth.uid()::text
  and exists (
    select 1 from public.vip_memberships vm
    where vm.user_id = auth.uid()
      and vm.status = 'active'
      and vm.expires_at > now()
  )
);

drop policy if exists "VIP users can remove their own unlinked message media" on storage.objects;
create policy "VIP users can remove their own unlinked message media"
on storage.objects for delete to authenticated
using (
  bucket_id = 'message-media'
  and (storage.foldername(name))[1] = auth.uid()::text
  and not exists (
    select 1 from public.empire_messages em
    where em.media_path = storage.objects.name
  )
);

drop policy if exists "Conversation participants can view message media" on storage.objects;
create policy "Conversation participants can view message media"
on storage.objects for select to authenticated
using (
  bucket_id = 'message-media'
  and exists (
    select 1 from public.empire_messages em
    where em.media_path = storage.objects.name
      and (em.sender_id = auth.uid() or em.receiver_id = auth.uid())
  )
);

create or replace function public.send_empire_media_message(
  p_receiver_id uuid,
  p_media_type text,
  p_media_path text
)
returns table (
  message_id uuid,
  charged_amount numeric,
  remaining_balance numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sender_id uuid := auth.uid();
  v_sender_wallet_id uuid;
  v_treasury_wallet_id uuid := '00000000-0000-0000-0000-000000000001'::uuid;
  v_balance numeric(30,8);
  v_fee numeric(30,8);
  v_message_id uuid;
  v_remaining numeric(30,8);
begin
  if v_sender_id is null then
    raise exception 'Authentication required';
  end if;
  if p_receiver_id is null or p_receiver_id = v_sender_id then
    raise exception 'Invalid recipient';
  end if;
  if p_media_type is null or p_media_type not in ('image','video','audio') then
    raise exception 'Unsupported media type';
  end if;
  if p_media_path is null
     or (storage.foldername(p_media_path))[1] <> v_sender_id::text
     or not exists (
       select 1 from storage.objects so
       where so.bucket_id = 'message-media'
         and so.name = p_media_path
         and so.owner_id = v_sender_id::text
     ) then
    raise exception 'Media upload not found or not owned by sender';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id = p_receiver_id and p.is_active = true
  ) then
    raise exception 'Recipient not found or inactive';
  end if;
  if not exists (
    select 1 from public.vip_memberships vm
    where vm.user_id = v_sender_id
      and vm.status = 'active'
      and vm.expires_at > now()
  ) then
    raise exception 'Active VIP membership is required to send photos, videos, or voice messages';
  end if;

  -- Match the existing secure text-message RPC: VIP messages cost 3 EMPC.
  v_fee := 3;

  select w.id, w.balance
    into v_sender_wallet_id, v_balance
  from public.empire_wallets w
  where w.user_id = v_sender_id and w.wallet_type = 'user'
  for update;
  if v_sender_wallet_id is null then raise exception 'EmpireCoin wallet not found'; end if;
  if v_balance < v_fee then
    raise exception 'Insufficient EMPC balance. Required: % EMPC', v_fee;
  end if;

  perform 1 from public.empire_wallets w
  where w.id = v_treasury_wallet_id and w.wallet_type = 'treasury'
  for update;
  if not found then raise exception 'EMPIRE treasury wallet not found'; end if;

  insert into public.empire_messages(sender_id, receiver_id, content, media_type, media_path)
  values (
    v_sender_id,
    p_receiver_id,
    case p_media_type when 'image' then '[Photo]' when 'video' then '[Video]' else '[Voice message]' end,
    p_media_type,
    p_media_path
  )
  returning id into v_message_id;

  update public.empire_wallets
  set balance = balance - v_fee
  where id = v_sender_wallet_id
  returning balance into v_remaining;

  update public.empire_wallets
  set balance = balance + v_fee
  where id = v_treasury_wallet_id;

  insert into public.empire_transactions (
    from_wallet_id, to_wallet_id, amount, transaction_type,
    description, external_reference, created_by
  ) values (
    v_sender_wallet_id, v_treasury_wallet_id, v_fee, 'message_fee',
    'VIP media message fee', 'message:' || v_message_id::text, v_sender_id
  );

  return query select v_message_id, v_fee, v_remaining;
end;
$$;

revoke all on function public.send_empire_media_message(uuid,text,text) from public, anon;
grant execute on function public.send_empire_media_message(uuid,text,text) to authenticated;
