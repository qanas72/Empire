-- EMPIRE: allow members to delete only their own submitted videos and files
-- Run once in Supabase SQL Editor.
-- Existing administrator delete permissions remain unchanged.

drop policy if exists "Creators can delete own videos" on public.videos;
create policy "Creators can delete own videos"
on public.videos
for delete
to authenticated
using (creator_id = auth.uid());

drop policy if exists "Creators can delete own video files" on storage.objects;
create policy "Creators can delete own video files"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'videos'
  and (storage.foldername(name))[1] = auth.uid()::text
);
