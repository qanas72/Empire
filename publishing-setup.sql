-- EMPIRE Community Publishing setup
-- Run this entire script in Supabase SQL Editor.

create table if not exists public.community_posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references auth.users(id) on delete cascade,
  author_name text not null default 'Empire member',
  content text not null default '',
  image_path text,
  is_removed boolean not null default false,
  created_at timestamptz not null default now(),
  constraint community_posts_content_or_image check (length(trim(content)) > 0 or image_path is not null)
);

create index if not exists community_posts_created_at_idx on public.community_posts(created_at desc);
create index if not exists community_posts_author_id_idx on public.community_posts(author_id);

create table if not exists public.post_reports (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reason text not null check (length(trim(reason)) between 1 and 1000),
  status text not null default 'pending' check (status in ('pending','action_taken','dismissed')),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(post_id, reporter_id)
);

create index if not exists post_reports_status_created_idx on public.post_reports(status, created_at desc);

alter table public.community_posts enable row level security;
alter table public.post_reports enable row level security;

drop policy if exists "Public can view active community posts" on public.community_posts;
create policy "Public can view active community posts" on public.community_posts
for select using (is_removed = false or public.is_admin());

drop policy if exists "Authenticated users can publish own posts" on public.community_posts;
create policy "Authenticated users can publish own posts" on public.community_posts
for insert to authenticated with check (author_id = auth.uid() and is_removed = false);

drop policy if exists "Authors can delete own posts" on public.community_posts;
create policy "Authors can delete own posts" on public.community_posts
for delete to authenticated using (author_id = auth.uid());

drop policy if exists "Admins can moderate community posts" on public.community_posts;
create policy "Admins can moderate community posts" on public.community_posts
for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Users can report posts" on public.post_reports;
create policy "Users can report posts" on public.post_reports
for insert to authenticated with check (
  reporter_id = auth.uid()
  and exists (select 1 from public.community_posts p where p.id = post_id and p.is_removed = false)
);

drop policy if exists "Admins can read post reports" on public.post_reports;
create policy "Admins can read post reports" on public.post_reports
for select to authenticated using (public.is_admin());

drop policy if exists "Admins can update post reports" on public.post_reports;
create policy "Admins can update post reports" on public.post_reports
for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Public image bucket for publication images.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('post-images', 'post-images', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "Public can view post images" on storage.objects;
create policy "Public can view post images" on storage.objects
for select using (bucket_id = 'post-images');

drop policy if exists "Users can upload own post images" on storage.objects;
create policy "Users can upload own post images" on storage.objects
for insert to authenticated with check (
  bucket_id = 'post-images' and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Users can delete own post images" on storage.objects;
create policy "Users can delete own post images" on storage.objects
for delete to authenticated using (
  bucket_id = 'post-images' and (storage.foldername(name))[1] = auth.uid()::text
);
