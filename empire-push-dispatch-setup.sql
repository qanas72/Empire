-- EMPIRE: connect newly-created in-app notifications to Web Push.
-- Prerequisites:
-- 1) Deploy supabase/functions/send-empire-push/index.ts as an Edge Function.
-- 2) In Supabase Edge Function Secrets, set EMPIRE_PUSH_WEBHOOK_SECRET to a long random value.
-- 3) Create a Vault secret with the EXACT same value and name it empire_push_webhook_secret.
--    Example (replace the placeholder; never commit your real secret to GitHub):
--    select vault.create_secret('REPLACE_WITH_THE_SAME_RANDOM_SECRET', 'empire_push_webhook_secret');
-- The public project URL below is not a secret.

create extension if not exists pg_net with schema extensions;

create or replace function public.dispatch_empire_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault, pg_temp
as $$
declare
  v_secret text;
  v_request_id bigint;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'empire_push_webhook_secret'
  limit 1;

  if v_secret is null or length(v_secret) < 32 then
    raise warning 'EMPIRE Push webhook secret is missing or too short; push was not dispatched.';
    return new;
  end if;

  select net.http_post(
    url := 'https://vubjkwbkuwndkjqfnyom.supabase.co/functions/v1/send-empire-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-empire-push-secret', v_secret
    ),
    body := jsonb_build_object('notification_id', new.id)::text,
    timeout_milliseconds := 5000
  ) into v_request_id;

  return new;
end;
$$;

drop trigger if exists empire_dispatch_push_after_notification on public.empire_notifications;
create trigger empire_dispatch_push_after_notification
after insert on public.empire_notifications
for each row execute function public.dispatch_empire_push_notification();
