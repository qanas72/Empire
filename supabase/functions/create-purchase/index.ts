import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const NETWORKS = {
  TRON: {
    payment_address: "TZ9PxtbEchvo1RSrTDjLvyeRHK1HPtmMmV",
    token_contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
    token_decimals: 6,
    label: "TRON (TRC20)",
  },
  BSC: {
    payment_address: "0xe8D7B16C603Ea5c2B7EEe87e567192Bf651c1DEA",
    token_contract: "0x55d398326f99059fF775485246999027B3197955",
    token_decimals: 18,
    label: "Binance-Peg BSC-USD (BEP20)",
  },
  TON: {
    payment_address: "UQBGbzaKDO0j_gddN5qguj15BrI6L9_VGcnUT0xP6rGXK7KT",
    token_contract: "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs",
    token_decimals: 6,
    label: "TON (USDT Jetton)",
  },
};

function secretValue(name: string): string {
  const raw = Deno.env.get(name);
  if (!raw) throw new Error(`Missing ${name} secret`);
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed.default === "string") return parsed.default;
  } catch { /* plain secret */ }
  return raw;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return Response.json({ error: "Method not allowed" }, { status: 405, headers: corsHeaders });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    if (!supabaseUrl) throw new Error("Missing SUPABASE_URL");
    const publishableKey = secretValue("SUPABASE_PUBLISHABLE_KEYS");
    const serviceKey = secretValue("SUPABASE_SECRET_KEYS");
    const authorization = req.headers.get("Authorization") || "";
    if (!authorization.startsWith("Bearer ")) {
      return Response.json({ error: "Authentication required" }, { status: 401, headers: corsHeaders });
    }

    const userClient = createClient(supabaseUrl, publishableKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) {
      return Response.json({ error: "Invalid or expired session" }, { status: 401, headers: corsHeaders });
    }

    const body = await req.json().catch(() => ({}));
    const videoId = String(body.video_id || "");
    const network = String(body.network || "").toUpperCase();
    if (!/^[0-9a-f-]{36}$/i.test(videoId)) {
      return Response.json({ error: "Invalid video ID" }, { status: 400, headers: corsHeaders });
    }
    if (!Object.prototype.hasOwnProperty.call(NETWORKS, network)) {
      return Response.json({ error: "Choose TRON, BSC, or TON network" }, { status: 400, headers: corsHeaders });
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: video, error: videoError } = await admin
      .from("videos")
      .select("id,title,access_type,price,approval_status")
      .eq("id", videoId)
      .maybeSingle();
    if (videoError) throw videoError;
    if (!video || video.approval_status !== "approved" || video.access_type !== "paid") {
      return Response.json({ error: "This paid video is not available" }, { status: 404, headers: corsHeaders });
    }

    const amount = String(video.price ?? "");
    if (!/^\d+(?:\.\d{1,6})?$/.test(amount) || Number(amount) <= 0) {
      return Response.json({ error: "Video price is invalid" }, { status: 400, headers: corsHeaders });
    }

    const userId = authData.user.id;
    const { data: paidPurchase, error: paidError } = await admin
      .from("purchases")
      .select("id,status")
      .eq("user_id", userId)
      .eq("video_id", videoId)
      .eq("status", "paid")
      .limit(1)
      .maybeSingle();
    if (paidError) throw paidError;
    if (paidPurchase) {
      return Response.json({ already_paid: true, purchase_id: paidPurchase.id }, { headers: corsHeaders });
    }

    const now = new Date();
    const { data: pendingRows, error: pendingError } = await admin
      .from("purchases")
      .select("id,network,status,expires_at,amount")
      .eq("user_id", userId)
      .eq("video_id", videoId)
      .eq("status", "pending")
      .order("created_at", { ascending: false })
      .limit(5);
    if (pendingError) throw pendingError;

    const existing = (pendingRows || []).find((p) =>
      p.network === network && p.expires_at && new Date(p.expires_at).getTime() > now.getTime()
    );

    if (existing) {
      const cfg = NETWORKS[network as keyof typeof NETWORKS];
      return Response.json({
        purchase_id: existing.id,
        amount: String(existing.amount),
        network,
        network_label: cfg.label,
        payment_address: cfg.payment_address,
        token_contract: cfg.token_contract,
        token_decimals: cfg.token_decimals,
        expires_at: existing.expires_at,
      }, { headers: corsHeaders });
    }

    const toExpire = (pendingRows || []).filter((p) => p.id);
    for (const pending of toExpire) {
      const { error: expireError } = await admin
        .from("purchases")
        .update({ status: "expired" })
        .eq("id", pending.id)
        .eq("status", "pending");
      if (expireError) throw expireError;
    }

    const expiresAt = new Date(now.getTime() + 30 * 60 * 1000).toISOString();
    const { data: purchase, error: insertError } = await admin
      .from("purchases")
      .insert({
        user_id: userId,
        video_id: videoId,
        amount,
        currency: network === "BSC" ? "BSC-USD" : "USDT",
        network,
        provider: "direct_usdt",
        status: "pending",
        expires_at: expiresAt,
      })
      .select("id,amount,network,expires_at")
      .single();
    if (insertError) throw insertError;

    const cfg = NETWORKS[network as keyof typeof NETWORKS];
    return Response.json({
      purchase_id: purchase.id,
      amount: String(purchase.amount),
      network,
      network_label: cfg.label,
      payment_address: cfg.payment_address,
      token_contract: cfg.token_contract,
      token_decimals: cfg.token_decimals,
      expires_at: purchase.expires_at,
    }, { headers: corsHeaders });
  } catch (error) {
    console.error("CREATE PURCHASE ERROR:", error);
    return Response.json({ error: error instanceof Error ? error.message : "Could not create purchase" }, { status: 500, headers: corsHeaders });
  }
});