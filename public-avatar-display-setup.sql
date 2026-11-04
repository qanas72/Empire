-- EMPIRE public avatar display
-- Profile photos are intentionally public profile information.
-- Keep uploads and deletes protected by the existing authenticated Storage policies.
do $$
begin
  update storage.buckets
  set public = true
  where id = 'avatars';

  if not found then
    raise exception 'Supabase Storage bucket "avatars" was not found. Create it before running this script.';
  end if;
end $$;
