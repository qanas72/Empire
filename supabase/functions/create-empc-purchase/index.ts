import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const PAYMENT_RAILS = {
  USDT_TRC20: {
    network: "TRON",
    recipient: "TZ9PxtbEchvo1RSrTDjLvyeRHK1HPtmMmV",
    token: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
    decimals: 6,
    label: "USDT · TRON (TRC20)",
  },
  USDT_BEP20: {
    network: "BSC",
    recipient: "0xe8D7B16C603Ea5c2B7EEe87e567192Bf651c1DEA",
    token: "0x55d398326f99059fF775485246999027B3197955",
    decimals: 18,
    label: "USDT · BNB Smart Chain (BEP20)",
  },
  USDT_TON: {
    network: "TON",
    recipient: "UQBGbzaKDO0j_gddN5qguj15BrI6L9_VGcnUT0xP6rGXK7KT",
    token: "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs",
    decimals: 6,
    label: "USDT · TON",
  },
} as const;

function secretValue(name: string): string {
  const raw = Deno.env.get(name);
  if (!raw) throw new Error(`Missing ${name} secret`);
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed.default === "string") return parsed.default;
  } catch { /* plain secret */ }
  return raw;
}

function decimalString(value: number, places: number): string {
  return value.toFixed(places).replace(/(?:\.0+|(?:(\.\d*?)0+))$/, "$1");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return Response.json({ error: "Method not allowed" }, { status: 405, headers: corsHeaders });
  }

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
    const paymentMethod = String(body.payment_method || "").toUpperCase();
    if (!Object.prototype.hasOwnProperty.call(PAYMENT_RAILS, paymentMethod)) {
      return Response.json({
        error: "Choose USDT_TRC20, USDT_BEP20, or USDT_TON. Native TON is not accepted.",
      }, { status: 400, headers: corsHeaders });
    }

    const rawUsd = String(body.usd_amount ?? "").trim();
    if (!/^\d{1,8}(?:\.\d{1,2})?$/.test(rawUsd)) {
      return Response.json({ error: "Enter an amount in USD with up to 2 decimal places." }, { status: 400, headers: corsHeaders });
    }
    const usdAmount = Number(rawUsd);
    if (!Number.isFinite(usdAmount) || usdAmount < 1 || usdAmount > 1000000) {
      return Response.json({ error: "Minimum purchase is $1 USDT." }, { status: 400, headers: corsHeaders });
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: setting, error: settingError } = await admin
      .from("empire_economic_settings")
      .select("setting_value")
      .eq("setting_key", "empc_usd_price")
      .maybeSingle();
    if (settingError) throw settingError;

    const rate = Number(setting?.setting_value);
    if (!Number.isFinite(rate) || rate <= 0) {
      throw new Error("The EMPC purchase rate is not configured correctly.");
    }

    const expectedEmpc = Math.floor((usdAmount / rate) * 100000000) / 100000000;
    if (!Number.isFinite(expectedEmpc) || expectedEmpc <= 0) {
      throw new Error("Could not calculate the EMPC purchase amount.");
    }

    const { data: treasury, error: treasuryError } = await admin
      .from("empire_wallets")
      .select("balance")
      .eq("id", "00000000-0000-0000-0000-000000000001")
      .eq("wallet_type", "treasury")
      .maybeSingle();
    if (treasuryError) throw treasuryError;
    if (!treasury || Number(treasury.balance) < expectedEmpc) {
      return Response.json({ error: "The EMPC treasury currently cannot cover this purchase amount." }, { status: 409, headers: corsHeaders });
    }

    const rail = PAYMENT_RAILS[paymentMethod as keyof typeof PAYMENT_RAILS];
    const { data: order, error: insertError } = await admin
      .from("empirecoin_purchase_orders")
      .insert({
        user_id: authData.user.id,
        payment_method: paymentMethod,
        payment_asset: "USDT",
        network: rail.network,
        token_contract: rail.token,
        recipient_address: rail.recipient,
        expected_payment_amount: decimalString(usdAmount, 2),
        payment_currency: "USDT",
        usd_amount: decimalString(usdAmount, 2),
        empc_rate_usd: decimalString(rate, 12),
        expected_empc: decimalString(expectedEmpc, 8),
        status: "pending",
        expires_at: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
      })
      .select("id,expected_payment_amount,payment_currency,usd_amount,empc_rate_usd,expected_empc,network,expires_at")
      .single();
    if (insertError) throw insertError;

    return Response.json({
      success: true,
      order_id: order.id,
      payment_method: paymentMethod,
      payment_label: rail.label,
      network: order.network,
      payment_amount: String(order.expected_payment_amount),
      payment_currency: order.payment_currency,
      usd_amount: String(order.usd_amount),
      empc_rate_usd: String(order.empc_rate_usd),
      expected_empc: String(order.expected_empc),
      recipient_address: rail.recipient,
      token_contract: rail.token,
      token_decimals: rail.decimals,
      expires_at: order.expires_at,
      minimum_usd: 1,
    }, { headers: corsHeaders });
  } catch (error) {
    console.error("CREATE EMPC PURCHASE ERROR:", error);
    return Response.json({
      error: error instanceof Error ? error.message : "Could not create EMPC purchase order",
    }, { status: 500, headers: corsHeaders });
  }
});
