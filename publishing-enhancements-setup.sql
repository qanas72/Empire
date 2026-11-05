-- EMPIRE publishing enhancements: multiple post images and account warnings
alter table public.community_posts
  add column if not exists image_paths text[] not null default '{}';

create table if not exists public.user_warnings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  admin_id uuid not null references auth.users(id) on delete restrict,
  message text not null check (length(trim(message)) between 5 and 2000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists user_warnings_user_created_idx
  on public.user_warnings(user_id, created_at desc);

alter table public.user_warnings enable row level security;

drop policy if exists "Users can read own warnings" on public.user_warnings;
create policy "Users can read own warnings"
on public.user_warnings for select to authenticated
using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Admins can issue warnings" on public.user_warnings;
create policy "Admins can issue warnings"
on public.user_warnings for insert to authenticated
with check (public.is_admin() and admin_id = auth.uid());

drop policy if exists "Users can mark own warnings read" on public.user_warnings;
create policy "Users can mark own warnings read"
on public.user_warnings for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "Admins can manage warnings" on public.user_warnings;
create policy "Admins can manage warnings"
on public.user_warnings for all to authenticated
using (public.is_admin())
with check (public.is_admin());

-- Allow up to seven images in the existing public post-images bucket.
update storage.buckets
set file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg','image/png','image/webp']
where id = 'post-images';
