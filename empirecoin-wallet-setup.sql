-- EMPIRE internal EmpireCoin (EMPC) wallet foundation
-- Creates one internal wallet per existing/new user and one treasury wallet.
-- Client roles can read their own balance/history but cannot alter balances or ledger rows.
-- No tokens or balances are minted by this migration.

create table if not exists public.empire_wallets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete cascade,
  wallet_type text not null check (wallet_type in ('user', 'treasury')),
  balance numeric(30, 8) not null default 0 check (balance >= 0),
  created_at timestamptz not null default now(),
  constraint empire_wallet_owner_type_check check (
    (wallet_type = 'user' and user_id is not null)
    or (wallet_type = 'treasury' and user_id is null)
  )
);

create unique index if not exists empire_wallets_single_treasury_idx
  on public.empire_wallets(wallet_type)
  where wallet_type = 'treasury';

create table if not exists public.empire_transactions (
  id uuid primary key default gen_random_uuid(),
  from_wallet_id uuid references public.empire_wallets(id),
  to_wallet_id uuid references public.empire_wallets(id),
  amount numeric(30, 8) not null check (amount > 0),
  transaction_type text not null check (transaction_type in (
    'purchase', 'message_fee', 'video_fee', 'reward',
    'referral_reward', 'vip_reward', 'refund',
    'admin_adjustment', 'treasury_transfer'
  )),
  description text,
  external_reference text unique,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint empire_transaction_distinct_wallets check (
    from_wallet_id is null or to_wallet_id is null or from_wallet_id <> to_wallet_id
  ),
  constraint empire_transaction_has_wallet check (
    from_wallet_id is not null or to_wallet_id is not null
  )
);

create index if not exists empire_transactions_from_created_idx
  on public.empire_transactions(from_wallet_id, created_at desc);
create index if not exists empire_transactions_to_created_idx
  on public.empire_transactions(to_wallet_id, created_at desc);

-- The treasury is an internal accounting account, not a user's personal wallet.
insert into public.empire_wallets (id, user_id, wallet_type, balance)
values ('00000000-0000-0000-0000-000000000001', null, 'treasury', 0)
on conflict (id) do nothing;

-- Backfill wallets for all existing accounts. New signups are handled by the trigger below.
insert into public.empire_wallets (user_id, wallet_type)
select id, 'user' from auth.users
on conflict (user_id) do nothing;

create or replace function public.create_empire_wallet_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.empire_wallets (user_id, wallet_type)
  values (new.id, 'user')
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_empire_wallet on auth.users;
create trigger on_auth_user_created_empire_wallet
after insert on auth.users
for each row execute function public.create_empire_wallet_for_new_user();

alter table public.empire_wallets enable row level security;
alter table public.empire_transactions enable row level security;

drop policy if exists "Users can read own EMPC wallet" on public.empire_wallets;
create policy "Users can read own EMPC wallet"
on public.empire_wallets for select
to authenticated
using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Users and admins can read related EMPC transactions" on public.empire_transactions;
create policy "Users and admins can read related EMPC transactions"
on public.empire_transactions for select
to authenticated
using (
  public.is_admin()
  or exists (
    select 1 from public.empire_wallets w
    where w.id = from_wallet_id and w.user_id = auth.uid()
  )
  or exists (
    select 1 from public.empire_wallets w
    where w.id = to_wallet_id and w.user_id = auth.uid()
  )
);

-- Explicitly deny client-side balance changes and ledger writes.
revoke all on public.empire_wallets from anon, authenticated;
revoke all on public.empire_transactions from anon, authenticated;
grant select on public.empire_wallets to authenticated;
grant select on public.empire_transactions to authenticated;

revoke all on function public.create_empire_wallet_for_new_user() from public, anon, authenticated;
