-- EMPIRE secure direct messaging with atomic EMPC fees
-- Regular users pay 5 EMPC/message; active VIP users pay 3 EMPC/message.
-- Fees move to the EMPIRE treasury. The client cannot insert messages or alter balances.

create table if not exists public.empire_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  receiver_id uuid not null references auth.users(id) on delete cascade,
  content text not null check (char_length(btrim(content)) between 1 and 5000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint empire_messages_no_self_message check (sender_id <> receiver_id)
);

create index if not exists empire_messages_sender_created_idx
  on public.empire_messages(sender_id, created_at desc);
create index if not exists empire_messages_receiver_created_idx
  on public.empire_messages(receiver_id, created_at desc);

alter table public.empire_messages enable row level security;

drop policy if exists "Conversation participants can read messages" on public.empire_messages;
create policy "Conversation participants can read messages"
on public.empire_messages for select
to authenticated
using (sender_id = auth.uid() or receiver_id = auth.uid());

-- No direct client writes: sending is only possible through the secure RPC below.
revoke all on public.empire_messages from anon, authenticated;
grant select on public.empire_messages to authenticated;

create or replace function public.send_empire_message(
  p_receiver_id uuid,
  p_content text
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
  v_is_vip boolean;
begin
  if v_sender_id is null then
    raise exception 'Authentication required';
  end if;

  if p_receiver_id is null or p_receiver_id = v_sender_id then
    raise exception 'Invalid recipient';
  end if;

  if p_content is null or char_length(btrim(p_content)) < 1
     or char_length(btrim(p_content)) > 5000 then
    raise exception 'Message must contain 1 to 5000 characters';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = p_receiver_id and p.is_active = true
  ) then
    raise exception 'Recipient not found or inactive';
  end if;

  select exists (
    select 1 from public.vip_memberships vm
    where vm.user_id = v_sender_id
      and vm.status = 'active'
      and vm.expires_at > now()
  ) into v_is_vip;

  v_fee := case when v_is_vip then 3 else 5 end;

  -- Lock the sender wallet to prevent concurrent overspending.
  select w.id, w.balance
    into v_sender_wallet_id, v_balance
  from public.empire_wallets w
  where w.user_id = v_sender_id and w.wallet_type = 'user'
  for update;

  if v_sender_wallet_id is null then
    raise exception 'EmpireCoin wallet not found';
  end if;

  if v_balance < v_fee then
    raise exception 'Insufficient EMPC balance. Required: % EMPC', v_fee;
  end if;

  -- Lock treasury before applying the atomic debit/credit.
  perform 1
  from public.empire_wallets w
  where w.id = v_treasury_wallet_id and w.wallet_type = 'treasury'
  for update;

  if not found then
    raise exception 'EMPIRE treasury wallet not found';
  end if;

  insert into public.empire_messages(sender_id, receiver_id, content)
  values (v_sender_id, p_receiver_id, btrim(p_content))
  returning id into v_message_id;

  update public.empire_wallets
  set balance = balance - v_fee
  where id = v_sender_wallet_id
  returning balance into v_remaining;

  update public.empire_wallets
  set balance = balance + v_fee
  where id = v_treasury_wallet_id;

  insert into public.empire_transactions (
    from_wallet_id,
    to_wallet_id,
    amount,
    transaction_type,
    description,
    external_reference,
    created_by
  ) values (
    v_sender_wallet_id,
    v_treasury_wallet_id,
    v_fee,
    'message_fee',
    'Direct message fee',
    'message:' || v_message_id::text,
    v_sender_id
  );

  return query select v_message_id, v_fee, v_remaining;
end;
$$;

revoke all on function public.send_empire_message(uuid, text) from public, anon;
grant execute on function public.send_empire_message(uuid, text) to authenticated;
