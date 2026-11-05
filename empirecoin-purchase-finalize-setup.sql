-- EMPIRE: secure atomic settlement for verified EMPC purchases
-- Run after empirecoin-purchase-orders-setup.sql.
-- Only the trusted Edge Function service role may call this RPC.

create or replace function public.finalize_verified_empc_purchase(
  p_order_id uuid,
  p_transaction_hash text,
  p_confirmations integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.empirecoin_purchase_orders%rowtype;
  v_treasury public.empire_wallets%rowtype;
  v_user_wallet public.empire_wallets%rowtype;
  v_reference text;
begin
  if p_order_id is null
     or p_transaction_hash is null
     or length(trim(p_transaction_hash)) < 20
     or length(trim(p_transaction_hash)) > 150 then
    raise exception 'Invalid purchase settlement details';
  end if;

  select * into v_order
  from public.empirecoin_purchase_orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Purchase order not found';
  end if;

  if v_order.status = 'confirmed' then
    if lower(v_order.transaction_hash) = lower(trim(p_transaction_hash)) then
      return jsonb_build_object(
        'success', true,
        'already_confirmed', true,
        'order_id', v_order.id,
        'credited_empc', v_order.expected_empc
      );
    end if;
    raise exception 'Purchase order was already settled with another transaction';
  end if;

  if v_order.status not in ('pending', 'confirming') then
    raise exception 'Purchase order is not payable';
  end if;

  if v_order.expires_at <= now() then
    update public.empirecoin_purchase_orders
      set status = 'expired', updated_at = now()
    where id = v_order.id;
    raise exception 'Purchase order has expired';
  end if;

  if exists (
    select 1 from public.empirecoin_purchase_orders
    where network = v_order.network
      and lower(transaction_hash) = lower(trim(p_transaction_hash))
      and id <> v_order.id
  ) then
    raise exception 'This transaction has already been used';
  end if;

  -- Lock both internal wallets; purchase credits are transferred from the
  -- pre-allocated treasury and do not mint new EMPC.
  select * into v_treasury
  from public.empire_wallets
  where id = '00000000-0000-0000-0000-000000000001'
    and wallet_type = 'treasury'
  for update;

  if not found then
    raise exception 'EMPIRE treasury wallet is unavailable';
  end if;

  select * into v_user_wallet
  from public.empire_wallets
  where user_id = v_order.user_id
    and wallet_type = 'user'
  for update;

  if not found then
    raise exception 'User EMPC wallet is unavailable';
  end if;

  if v_treasury.balance < v_order.expected_empc then
    raise exception 'Treasury has insufficient EMPC allocation';
  end if;

  v_reference := 'empc-purchase:' || v_order.id::text;

  if exists (
    select 1 from public.empire_transactions
    where external_reference = v_reference
  ) then
    raise exception 'Purchase ledger entry already exists';
  end if;

  update public.empire_wallets
    set balance = balance - v_order.expected_empc
  where id = v_treasury.id;

  update public.empire_wallets
    set balance = balance + v_order.expected_empc
  where id = v_user_wallet.id;

  insert into public.empire_transactions (
    from_wallet_id, to_wallet_id, amount, transaction_type,
    description, external_reference, created_by
  ) values (
    v_treasury.id, v_user_wallet.id, v_order.expected_empc, 'purchase',
    'Verified EMPC purchase via ' || v_order.payment_method,
    v_reference, v_order.user_id
  );

  update public.empirecoin_purchase_orders
    set status = 'confirmed',
        transaction_hash = trim(p_transaction_hash),
        confirmations = greatest(coalesce(p_confirmations, 0), 0),
        verified_at = now(),
        updated_at = now()
  where id = v_order.id;

  return jsonb_build_object(
    'success', true,
    'already_confirmed', false,
    'order_id', v_order.id,
    'credited_empc', v_order.expected_empc
  );
end;
$$;

revoke all on function public.finalize_verified_empc_purchase(uuid, text, integer)
  from public, anon, authenticated;
grant execute on function public.finalize_verified_empc_purchase(uuid, text, integer)
  to service_role;

comment on function public.finalize_verified_empc_purchase(uuid, text, integer) is
  'Atomically confirms a server-verified EMPC payment and transfers EMPC from treasury allocation to the buyer. Never call from a browser client.';
