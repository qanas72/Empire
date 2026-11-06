-- EMPIRE Support Replies
-- Run once in Supabase SQL Editor after support-requests-setup.sql.
alter table public.support_requests
  add column if not exists admin_reply text,
  add column if not exists replied_at timestamptz,
  add column if not exists replied_by uuid references auth.users(id) on delete set null;

drop policy if exists "Users can view their own support requests" on public.support_requests;
create policy "Users can view their own support requests"
  on public.support_requests for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Admins can view support requests" on public.support_requests;
create policy "Admins can view support requests"
  on public.support_requests for select to authenticated
  using (public.is_admin() = true);

drop policy if exists "Admins can update support requests" on public.support_requests;
create policy "Admins can update support requests"
  on public.support_requests for update to authenticated
  using (public.is_admin() = true)
  with check (public.is_admin() = true);
