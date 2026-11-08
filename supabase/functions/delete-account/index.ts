import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const json = (status: number, body: Record<string, unknown>) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  if (req.method !== "POST") return json(405, { success: false, error: "Method not allowed." });

  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!token) return json(401, { success: false, error: "Please sign in again." });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) {
    return json(500, { success: false, error: "Account deletion service is not configured." });
  }

  const authClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser(token);
  if (authError || !authData.user) return json(401, { success: false, error: "Your session is invalid. Sign in again." });

  const user = authData.user;
  const adminIds = [
    "8166f8a9-fdc3-43a4-85c7-53ec1dbbde0e",
    "7c5f5c13-b106-4c7c-9bd5-9339576bfe7a",
  ];
  if (adminIds.includes(user.id)) {
    return json(403, { success: false, error: "Administrator accounts cannot be deleted through this option." });
  }

  const db = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Preserve all financial records: block deletion if this account has any ledger history.
  const { data: wallet, error: walletError } = await db
    .from("empire_wallets")
    .select("id,balance,wallet_type")
    .eq("user_id", user.id)
    .eq("wallet_type", "user")
    .maybeSingle();
  if (walletError) return json(500, { success: false, error: "Could not verify your EMPC wallet. No account changes were made." });

  if (wallet && Number(wallet.balance || 0) !== 0) {
    return json(409, { success: false, error: "This account has an EMPC balance. For safety, transfer or resolve the balance before account deletion." });
  }

  if (wallet) {
    const { data: ledgerRows, error: ledgerError } = await db
      .from("empire_transactions")
      .select("id")
      .or(`from_wallet_id.eq.${wallet.id},to_wallet_id.eq.${wallet.id}`)
      .limit(1);
    if (ledgerError) return json(500, { success: false, error: "Could not verify transaction history. No account changes were made." });
    if (ledgerRows?.length) {
      return json(409, { success: false, error: "This account has financial transaction history. It is protected and cannot be deleted automatically. Please contact EMPIRE support." });
    }
  }

  // Do not silently erase an active VIP entitlement.
  const { data: vipRows, error: vipError } = await db
    .from("vip_memberships")
    .select("id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .gt("expires_at", new Date().toISOString())
    .limit(1);
  if (vipError) return json(500, { success: false, error: "Could not verify VIP membership. No account changes were made." });
  if (vipRows?.length) {
    return json(409, { success: false, error: "This account has an active VIP membership. Please contact EMPIRE support before deleting it." });
  }

  const { error: deleteError } = await db.auth.admin.deleteUser(user.id);
  if (deleteError) {
    console.error("delete-account failed for user", user.id, deleteError.message);
    return json(500, { success: false, error: "The account could not be deleted because related records may still exist. No further changes were made. Please contact EMPIRE support." });
  }

  return json(200, { success: true, message: "Your EMPIRE account has been deleted." });
});
