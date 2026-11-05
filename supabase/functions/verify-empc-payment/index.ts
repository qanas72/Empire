import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { Address } from "npm:@ton/core";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const RAILS = {
  USDT_TRC20: {
    network: "TRON",
    recipient: "TZ9PxtbEchvo1RSrTDjLvyeRHK1HPtmMmV",
    token: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
    decimals: 6,
  },
  USDT_BEP20: {
    network: "BSC",
    recipient: "0xe8D7B16C603Ea5c2B7EEe87e567192Bf651c1DEA",
    token: "0x55d398326f99059fF775485246999027B3197955",
    decimals: 18,
  },
  USDT_TON: {
    network: "TON",
    recipient: "UQBGbzaKDO0j_gddN5qguj15BrI6L9_VGcnUT0xP6rGXK7KT",
    token: "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs",
    decimals: 6,
  },
} as const;

const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

function secretValue(name: string): string {
  const raw = Deno.env.get(name);
  if (!raw) throw new Error(`Missing ${name} secret`);
  try {
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed.default === "string") return parsed.default;
  } catch { /* plain secret */ }
  return raw;
}

function decimalToUnits(value: string, decimals: number): bigint {
  if (!/^\d+(?:\.\d+)?$/.test(value)) throw new Error("Invalid payment amount");
  const [whole, fraction = ""] = value.split(".");
  if (fraction.length > decimals) throw new Error("Payment amount precision is invalid");
  return BigInt(whole) * (10n ** BigInt(decimals)) +
    BigInt((fraction + "0".repeat(decimals)).slice(0, decimals) || "0");
}

function topicAddress(address: string): string {
  return "0x" + address.toLowerCase().replace(/^0x/, "").padStart(64, "0");
}

async function rpc(url: string, method: string, params: unknown[]) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (!response.ok) throw new Error("BSC RPC request failed");
  const data = await response.json();
  if (data.error) throw new Error(data.error.message || "BSC RPC error");
  return data.result;
}

async function verifyBsc(txid: string, amount: string, rail: typeof RAILS.USDT_BEP20) {
  if (!/^0x[0-9a-f]{64}$/i.test(txid)) return { verified: false, confirmations: 0 };
  const rpcUrl = Deno.env.get("BSC_RPC_URL") || "https://bsc-dataseed.bnbchain.org";
  const receipt = await rpc(rpcUrl, "eth_getTransactionReceipt", [txid]);
  if (!receipt || receipt.status !== "0x1" || !receipt.blockNumber) {
    return { verified: false, confirmations: 0 };
  }
  const latestHex = await rpc(rpcUrl, "eth_blockNumber", []);
  const confirmations = Number(BigInt(latestHex) - BigInt(receipt.blockNumber) + 1n);
  if (!Number.isSafeInteger(confirmations) || confirmations < 15) {
    return { verified: false, confirmations: Math.max(0, confirmations || 0) };
  }

  const decimalsHex = await rpc(rpcUrl, "eth_call", [{ to: rail.token, data: "0x313ce567" }, "latest"]);
  const tokenDecimals = Number(BigInt(decimalsHex));
  if (!Number.isInteger(tokenDecimals) || tokenDecimals !== rail.decimals) {
    throw new Error("BSC USDT token decimals did not match configuration");
  }

  const expected = decimalToUnits(amount, rail.decimals);
  const recipientTopic = topicAddress(rail.recipient);
  for (const log of (receipt.logs || [])) {
    if (String(log.address || "").toLowerCase() !== rail.token.toLowerCase()) continue;
    const topics = log.topics || [];
    if (String(topics[0] || "").toLowerCase() !== TRANSFER_TOPIC) continue;
    if (String(topics[2] || "").toLowerCase() !== recipientTopic) continue;
    if (BigInt(log.data || "0x0") === expected) return { verified: true, confirmations };
  }
  return { verified: false, confirmations };
}

async function verifyTron(txid: string, amount: string, createdAt: string, rail: typeof RAILS.USDT_TRC20) {
  if (!/^[0-9a-f]{64}$/i.test(txid)) return { verified: false, confirmations: 0 };
  const apiKey = Deno.env.get("TRONGRID_API_KEY");
  if (!apiKey) throw new Error("TRONGRID_API_KEY is not configured");
  const url = new URL(`https://api.trongrid.io/v1/accounts/${rail.recipient}/transactions/trc20`);
  url.searchParams.set("only_confirmed", "true");
  url.searchParams.set("limit", "200");
  url.searchParams.set("contract_address", rail.token);
  url.searchParams.set("only_to", "true");
  url.searchParams.set("min_timestamp", String(Math.max(0, new Date(createdAt).getTime() - 120000)));
  const response = await fetch(url, { headers: { "TRON-PRO-API-KEY": apiKey } });
  if (!response.ok) throw new Error("TRON transaction lookup failed");
  const payload = await response.json();
  const expected = decimalToUnits(amount, rail.decimals).toString();
  const match = (payload.data || []).some((item: any) =>
    String(item.transaction_id || "").toLowerCase() === txid.toLowerCase() &&
    String(item.to || "").toLowerCase() === rail.recipient.toLowerCase() &&
    String(item.token_info?.address || "").toLowerCase() === rail.token.toLowerCase() &&
    String(item.value) === expected
  );
  return { verified: match, confirmations: match ? 1 : 0 };
}

function tonHashToHex(hash: string): string | null {
  const value = hash.trim().replace(/^0x/i, "");
  if (/^[0-9a-f]{64}$/i.test(value)) return value.toLowerCase();
  const b64 = value.replace(/-/g, "+").replace(/_/g, "/");
  try {
    const binary = atob(b64 + "=".repeat((4 - b64.length % 4) % 4));
    if (binary.length !== 32) return null;
    return Array.from(binary, (ch) => ch.charCodeAt(0).toString(16).padStart(2, "0")).join("");
  } catch { return null; }
}

async function verifyTon(txid: string, amount: string, createdAt: string, rail: typeof RAILS.USDT_TON) {
  const wantedHash = tonHashToHex(txid);
  if (!wantedHash) return { verified: false, confirmations: 0 };
  const apiKey = Deno.env.get("TONCENTER_API_KEY");
  if (!apiKey) throw new Error("TONCENTER_API_KEY is not configured");

  const url = new URL("https://toncenter.com/api/v3/jetton/transfers");
  url.searchParams.set("owner_address", rail.recipient);
  url.searchParams.set("jetton_master", rail.token);
  url.searchParams.set("direction", "in");
  url.searchParams.set("limit", "1000");
  url.searchParams.set("sort", "desc");
  const createdSeconds = Math.max(0, Math.floor(new Date(createdAt).getTime() / 1000) - 120);
  if (Number.isFinite(createdSeconds)) url.searchParams.set("start_utime", String(createdSeconds));

  const response = await fetch(url, { headers: { "X-API-Key": apiKey } });
  if (!response.ok) throw new Error("TON transaction lookup failed");
  const payload = await response.json();
  const expectedAmount = decimalToUnits(amount, rail.decimals).toString();
  const expectedDestination = Address.parse(rail.recipient).toRawString();
  for (const transfer of (payload.jetton_transfers || [])) {
    if (tonHashToHex(String(transfer.transaction_hash || "")) !== wantedHash) continue;
    try {
      if (Address.parse(String(transfer.jetton_master || "")).toRawString() !== Address.parse(rail.token).toRawString()) continue;
      if (Address.parse(String(transfer.destination || "").trim()).toRawString() !== expectedDestination) continue;
      if (String(transfer.amount) !== expectedAmount) continue;
      if (transfer.transaction_aborted !== false) continue;
      return { verified: true, confirmations: 1 };
    } catch { continue; }
  }
  return { verified: false, confirmations: 0 };
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
    const orderId = String(body.order_id || "");
    const txid = String(body.transaction_hash || body.txid || "").trim();
    if (!/^[0-9a-f-]{36}$/i.test(orderId) || txid.length < 20 || txid.length > 150) {
      return Response.json({ error: "Invalid order ID or transaction hash" }, { status: 400, headers: corsHeaders });
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: order, error: orderError } = await admin
      .from("empirecoin_purchase_orders")
      .select("id,user_id,payment_method,payment_asset,network,token_contract,recipient_address,expected_payment_amount,payment_currency,status,expires_at,created_at")
      .eq("id", orderId)
      .eq("user_id", authData.user.id)
      .maybeSingle();
    if (orderError) throw orderError;
    if (!order) return Response.json({ error: "Purchase order not found" }, { status: 404, headers: corsHeaders });

    if (order.status === "confirmed") {
      return Response.json({ success: true, status: "confirmed", message: "This order has already been credited." }, { headers: corsHeaders });
    }
    if (!["pending", "confirming"].includes(order.status)) {
      return Response.json({ error: "This purchase order is not payable." }, { status: 409, headers: corsHeaders });
    }
    if (order.expires_at && new Date(order.expires_at).getTime() <= Date.now()) {
      return Response.json({ error: "This purchase order has expired." }, { status: 410, headers: corsHeaders });
    }

    const method = String(order.payment_method || "").toUpperCase();
    if (!Object.prototype.hasOwnProperty.call(RAILS, method) ||
        order.payment_asset !== "USDT" || order.payment_currency !== "USDT") {
      return Response.json({ error: "This order does not use an approved USDT payment method." }, { status: 400, headers: corsHeaders });
    }
    const rail = RAILS[method as keyof typeof RAILS];
    if (order.network !== rail.network ||
        String(order.recipient_address || "").toLowerCase() !== rail.recipient.toLowerCase() ||
        String(order.token_contract || "").toLowerCase() !== rail.token.toLowerCase()) {
      return Response.json({ error: "Payment order configuration does not match the approved receiving wallet." }, { status: 409, headers: corsHeaders });
    }

    let result: { verified: boolean; confirmations: number };
    if (method === "USDT_TRC20") {
      result = await verifyTron(txid, String(order.expected_payment_amount), String(order.created_at), rail as typeof RAILS.USDT_TRC20);
    } else if (method === "USDT_BEP20") {
      result = await verifyBsc(txid, String(order.expected_payment_amount), rail as typeof RAILS.USDT_BEP20);
    } else {
      result = await verifyTon(txid, String(order.expected_payment_amount), String(order.created_at), rail as typeof RAILS.USDT_TON);
    }

    if (!result.verified) {
      return Response.json({
        success: false,
        status: "pending",
        confirmations: result.confirmations,
        error: "No matching confirmed USDT transfer was found. Check the network, exact amount, receiving address, token, and transaction hash.",
      }, { status: 202, headers: corsHeaders });
    }

    const { data: settled, error: finalizeError } = await admin.rpc("finalize_verified_empc_purchase", {
      p_order_id: order.id,
      p_transaction_hash: txid,
      p_confirmations: result.confirmations,
    });
    if (finalizeError) {
      console.error("FINALIZE EMPC PURCHASE ERROR:", finalizeError);
      return Response.json({ error: finalizeError.message || "Could not credit the EMPC purchase." }, { status: 409, headers: corsHeaders });
    }

    return Response.json({
      success: true,
      status: "confirmed",
      order_id: order.id,
      credited_empc: settled?.credited_empc ?? null,
      confirmations: result.confirmations,
    }, { headers: corsHeaders });
  } catch (error) {
    console.error("VERIFY EMPC PAYMENT ERROR:", error);
    return Response.json({
      error: error instanceof Error ? error.message : "EMPC payment verification failed",
    }, { status: 500, headers: corsHeaders });
  }
});
