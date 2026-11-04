import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { Address } from "npm:@ton/core";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const CONFIG = {
  TRON: {
    recipient: "TZ9PxtbEchvo1RSrTDjLvyeRHK1HPtmMmV",
    token: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
    decimals: 6,
  },
  BSC: {
    recipient: "0xe8D7B16C603Ea5c2B7EEe87e567192Bf651c1DEA",
    token: "0x55d398326f99059fF775485246999027B3197955",
    decimals: 18,
  },
  TON: {
    recipient: "UQBGbzaKDO0j_gddN5qguj15BrI6L9_VGcnUT0xP6rGXK7KT",
    token: "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs",
    decimals: 6,
  },
};

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
  return BigInt(whole) * (10n ** BigInt(decimals)) + BigInt((fraction + "0".repeat(decimals)).slice(0, decimals) || "0");
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

async function verifyBsc(txid: string, amount: string): Promise<boolean> {
  if (!/^0x[0-9a-f]{64}$/i.test(txid)) return false;
  const rpcUrl = Deno.env.get("BSC_RPC_URL") || "https://bsc-dataseed.bnbchain.org";
  const receipt = await rpc(rpcUrl, "eth_getTransactionReceipt", [txid]);
  if (!receipt || receipt.status !== "0x1" || !receipt.blockNumber) return false;

  const latestHex = await rpc(rpcUrl, "eth_blockNumber", []);
  const confirmations = BigInt(latestHex) - BigInt(receipt.blockNumber) + 1n;
  if (confirmations < 15n) return false;

  const expected = decimalToUnits(amount, CONFIG.BSC.decimals);
  const recipientTopic = topicAddress(CONFIG.BSC.recipient);
  for (const log of (receipt.logs || [])) {
    if (String(log.address || "").toLowerCase() !== CONFIG.BSC.token.toLowerCase()) continue;
    const topics = log.topics || [];
    if (String(topics[0] || "").toLowerCase() !== TRANSFER_TOPIC) continue;
    if (String(topics[2] || "").toLowerCase() !== recipientTopic) continue;
    if (BigInt(log.data || "0x0") === expected) return true;
  }
  return false;
}

async function verifyTron(txid: string, amount: string): Promise<boolean> {
  if (!/^[0-9a-f]{64}$/i.test(txid)) return false;
  const apiKey = Deno.env.get("TRONGRID_API_KEY");
  if (!apiKey) throw new Error("TRONGRID_API_KEY is not configured");
  const url = new URL(`https://api.trongrid.io/v1/accounts/${CONFIG.TRON.recipient}/transactions/trc20`);
  url.searchParams.set("only_confirmed", "true");
  url.searchParams.set("limit", "200");
  url.searchParams.set("contract_address", CONFIG.TRON.token);
  const response = await fetch(url, { headers: { "TRON-PRO-API-KEY": apiKey } });
  if (!response.ok) throw new Error("TRON transaction lookup failed");
  const payload = await response.json();
  const expected = decimalToUnits(amount, CONFIG.TRON.decimals).toString();
  const matches = (payload.data || []).filter((item: any) =>
    String(item.transaction_id || "").toLowerCase() === txid.toLowerCase() &&
    String(item.to || "").toLowerCase() === CONFIG.TRON.recipient.toLowerCase() &&
    String(item.token_info?.address || "").toLowerCase() === CONFIG.TRON.token.toLowerCase() &&
    String(item.value) === expected
  );
  return matches.length > 0;
}

function tonHashToHex(hash: string): string | null {
  const value = hash.trim().replace(/^0x/i, "");
  if (/^[0-9a-f]{64}$/i.test(value)) return value.toLowerCase();
  const b64 = value.replace(/-/g, "+").replace(/_/g, "/");
  try {
    const binary = atob(b64 + "=".repeat((4 - b64.length % 4) % 4));
    if (binary.length !== 32) return null;
    return Array.from(binary, (ch) => ch.charCodeAt(0).toString(16).padStart(2, "0")).join("");
  } catch {
    return null;
  }
}

async function verifyTon(txid: string, amount: string, createdAt: string): Promise<boolean> {
  const wantedHash = tonHashToHex(txid);
  if (!wantedHash) return false;
  const apiKey = Deno.env.get("TONCENTER_API_KEY");
  if (!apiKey) throw new Error("TONCENTER_API_KEY is not configured");

  const url = new URL("https://toncenter.com/api/v3/jetton/transfers");
  url.searchParams.set("owner_address", CONFIG.TON.recipient);
  url.searchParams.set("jetton_master", CONFIG.TON.token);
  url.searchParams.set("direction", "in");
  url.searchParams.set("limit", "1000");
  url.searchParams.set("sort", "desc");
  const createdSeconds = Math.max(0, Math.floor(new Date(createdAt).getTime() / 1000) - 120);
  if (Number.isFinite(createdSeconds)) url.searchParams.set("start_utime", String(createdSeconds));

  const response = await fetch(url, { headers: { "X-API-Key": apiKey } });
  if (!response.ok) throw new Error("TON transaction lookup failed");
  const payload = await response.json();
  const expectedAmount = decimalToUnits(amount, CONFIG.TON.decimals).toString();
  const expectedDestination = Address.parse(CONFIG.TON.recipient).toRawString();
  for (const transfer of (payload.jetton_transfers || [])) {
    if (tonHashToHex(String(transfer.transaction_hash || "")) !== wantedHash) continue;
    if (String(transfer.jetton_master || "").toLowerCase() !== CONFIG.TON.token.toLowerCase()) continue;
    if (Address.parse(String(transfer.destination)).toRawString() !== expectedDestination) continue;
    if (String(transfer.amount) !== expectedAmount) continue;
    if (transfer.transaction_aborted !== false) continue;
    return true;
  }
  return false;
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
    const purchaseId = String(body.purchase_id || "");
    const txid = String(body.txid || body.transaction_hash || "").trim();
    if (!/^[0-9a-f-]{36}$/i.test(purchaseId) || txid.length < 20 || txid.length > 150) {
      return Response.json({ error: "Invalid purchase ID or transaction ID" }, { status: 400, headers: corsHeaders });
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: purchase, error: purchaseError } = await admin
      .from("purchases")
      .select("id,user_id,video_id,amount,network,status,expires_at,created_at,provider_payment_id")
      .eq("id", purchaseId)
      .eq("user_id", authData.user.id)
      .maybeSingle();
    if (purchaseError) throw purchaseError;
    if (!purchase) return Response.json({ error: "Purchase not found" }, { status: 404, headers: corsHeaders });
    if (purchase.status === "paid") return Response.json({ success: true, status: "paid" }, { headers: corsHeaders });
    if (purchase.status !== "pending") return Response.json({ error: "Purchase is not pending" }, { status: 409, headers: corsHeaders });
    if (purchase.expires_at && new Date(purchase.expires_at).getTime() <= Date.now()) {
      return Response.json({ error: "Payment request has expired" }, { status: 410, headers: corsHeaders });
    }

    const network = String(purchase.network || "").toUpperCase();
    let verified = false;
    if (network === "TRON") verified = await verifyTron(txid, String(purchase.amount));
    else if (network === "BSC") verified = await verifyBsc(txid, String(purchase.amount));
    else if (network === "TON") verified = await verifyTon(txid, String(purchase.amount), String(purchase.created_at));
    else return Response.json({ error: "Unsupported payment network" }, { status: 400, headers: corsHeaders });

    if (!verified) {
      return Response.json({
        success: false,
        status: "pending",
        error: "No matching confirmed USDT transfer was found. Check the network, amount, recipient, token contract, and transaction ID.",
      }, { status: 202, headers: corsHeaders });
    }

    const { error: finalizeError } = await admin.rpc("finalize_verified_video_purchase", {
      p_purchase_id: purchase.id,
      p_transaction_hash: txid,
    });
    if (finalizeError) {
      console.error("FINALIZE VIDEO PURCHASE ERROR:", finalizeError);
      return Response.json({ error: finalizeError.message || "Could not finalize payment" }, { status: 409, headers: corsHeaders });
    }

    return Response.json({ success: true, status: "paid" }, { headers: corsHeaders });
  } catch (error) {
    console.error("VERIFY PAYMENT ERROR:", error);
    return Response.json({ error: error instanceof Error ? error.message : "Payment verification failed" }, { status: 500, headers: corsHeaders });
  }
});