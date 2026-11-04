-- EMPIRE EMPC purchase-order foundation
-- Orders are created/updated only by trusted server-side Edge Functions using service_role.
-- A submitted transaction hash is NOT proof of payment and never credits a wallet by itself.

create table if not exists public.empirecoin_purchase_orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  payment_method text not null check (payment_method in (
    'TON', 'USDT_TON', 'USDT_BEP20', 'USDT_TRC20'
  )),
  payment_asset text not null check (payment_asset in ('TON', 'USDT')),
  network text not null check (network in ('TON', 'BSC', 'TRON')),
  token_contract text,
  recipient_address text not null,
  expected_payment_amount numeric(30, 12) not null check (expected_payment_amount > 0),
  payment_currency text not null check (payment_currency in ('TON', 'USDT')),
  usd_amount numeric(18, 2) not null check (usd_amount >= 1),
  empc_rate_usd numeric(24, 12) not null check (empc_rate_usd > 0),
  expected_empc numeric(30, 8) not null check (expected_empc > 0),
  transaction_hash text,
  status text not null default 'pending' check (status in (
    'pending', 'confirming', 'confirmed', 'rejected', 'expired'
  )),
  confirmations integer not null default 0 check (confirmations >= 0),
  verified_at timestamptz,
  rejection_reason text,
  expires_at timestamptz not null default (now() + interval '2 hours'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint empirecoin_purchase_confirmed_fields_check check (
    status <> 'confirmed' or (transaction_hash is not null and verified_at is not null)
  )
);

-- Prevent the same on-chain transaction from being attached to multiple orders
-- on the same network, regardless of capitalization.
create unique index if not exists empirecoin_purchase_network_tx_unique
  on public.empirecoin_purchase_orders (network, lower(transaction_hash))
  where transaction_hash is not null;

create index if not exists empirecoin_purchase_user_created_idx
  on public.empirecoin_purchase_orders (user_id, created_at desc);

create index if not exists empirecoin_purchase_status_created_idx
  on public.empirecoin_purchase_orders (status, created_at desc);

alter table public.empirecoin_purchase_orders enable row level security;

drop policy if exists "Users can read own EMPC purchase orders" on public.empirecoin_purchase_orders;
create policy "Users can read own EMPC purchase orders"
  on public.empirecoin_purchase_orders
  for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- No INSERT, UPDATE, or DELETE policy is intentionally created.
-- Browser clients cannot create/approve orders or change payment status.
revoke all on public.empirecoin_purchase_orders from anon, authenticated;
grant select on public.empirecoin_purchase_orders to authenticated;

comment on table public.empirecoin_purchase_orders is
  'EMPC external payment orders. Only trusted server-side verification may confirm and credit an order.';
comment on column public.empirecoin_purchase_orders.empc_rate_usd is
  'Immutable USD/EMPC rate snapshot for this order; default launch rate is configured server-side.';
comment on column public.empirecoin_purchase_orders.recipient_address is
  'Receiving address snapshot; server verifier must compare the on-chain recipient exactly.';
