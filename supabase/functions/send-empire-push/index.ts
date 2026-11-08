import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as webpush from "npm:web-push";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-empire-push-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return Response.json({ error: "Method not allowed" }, { status: 405, headers: corsHeaders });

  try {
    const expectedSecret = Deno.env.get("EMPIRE_PUSH_WEBHOOK_SECRET");
    const suppliedSecret = req.headers.get("x-empire-push-secret");
    if (!expectedSecret || !suppliedSecret || suppliedSecret !== expectedSecret) {
      return Response.json({ error: "Unauthorized" }, { status: 401, headers: corsHeaders });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY");
    const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY");
    const vapidSubject = Deno.env.get("VAPID_SUBJECT") || "mailto:support@empire.example";
    if (!supabaseUrl || !serviceRoleKey || !vapidPublicKey || !vapidPrivateKey) {
      throw new Error("Push server secrets are not fully configured.");
    }

    const body = await req.json().catch(() => ({}));
    const notificationId = String(body.notification_id || "");
    if (!/^[0-9a-f-]{36}$/i.test(notificationId)) {
      return Response.json({ error: "Invalid notification ID" }, { status: 400, headers: corsHeaders });
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: notification, error: notificationError } = await admin
      .from("empire_notifications")
      .select("id,user_id,title,body,target_url,created_at")
      .eq("id", notificationId)
      .maybeSingle();
    if (notificationError) throw notificationError;
    if (!notification) return Response.json({ success: true, skipped: "notification_not_found" }, { headers: corsHeaders });

    // Avoid replaying old notifications if the database webhook is retried much later.
    if (Date.now() - new Date(notification.created_at).getTime() > 10 * 60 * 1000) {
      return Response.json({ success: true, skipped: "notification_too_old" }, { headers: corsHeaders });
    }

    webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);
    const { data: subscriptions, error: subscriptionsError } = await admin
      .from("empire_push_subscriptions")
      .select("id,endpoint,p256dh,auth")
      .eq("user_id", notification.user_id)
      .eq("enabled", true)
      .limit(100);
    if (subscriptionsError) throw subscriptionsError;

    const payload = JSON.stringify({
      title: notification.title || "EMPIRE",
      body: notification.body || "You have a new notification.",
      url: notification.target_url || "./notifications.html",
      tag: notification.id,
      icon: "./icons/empire-icon.svg",
    });

    let sent = 0;
    let failed = 0;
    for (const row of subscriptions || []) {
      try {
        await webpush.sendNotification({
          endpoint: row.endpoint,
          keys: { p256dh: row.p256dh, auth: row.auth },
        }, payload, { TTL: 60 * 60 });
        sent++;
        await admin.from("empire_push_subscriptions")
          .update({ last_seen_at: new Date().toISOString() })
          .eq("id", row.id);
      } catch (error) {
        failed++;
        const statusCode = Number((error as { statusCode?: number })?.statusCode || 0);
        if (statusCode === 404 || statusCode === 410) {
          await admin.from("empire_push_subscriptions").delete().eq("id", row.id);
        }
        console.error("Push delivery failed", statusCode);
      }
    }

    return Response.json({ success: true, sent, failed }, { headers: corsHeaders });
  } catch (error) {
    console.error("EMPIRE PUSH ERROR:", error);
    return Response.json({ error: error instanceof Error ? error.message : "Push delivery failed" }, { status: 500, headers: corsHeaders });
  }
});
