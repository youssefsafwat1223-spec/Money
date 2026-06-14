import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-app-version",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const appVersion = req.headers.get("x-app-version") ?? "unknown";
  console.log(`catalog-flags requested by app version: ${appVersion}`);

  try {
    const url = new URL(req.url);
    const country = url.searchParams.get("country")?.trim().toUpperCase();

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey =
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
      Deno.env.get("SUPABASE_ANON_KEY");
    if (!supabaseUrl || !serviceKey) {
      return json({ error: "Supabase environment is not configured" }, 500);
    }

    const client = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    let query = client
      .from("feature_flags")
      .select("key, value_type, value, rollout_percent, target_countries, is_active")
      .eq("is_active", true);

    const { data, error } = await query;
    if (error) return json({ error: error.message }, 500);

    // Filter by country if provided: include flags where target_countries is
    // empty (meaning all countries) or contains the requested country.
    const flags = (data ?? []).filter((flag) => {
      if (!country) return true;
      const targets: string[] = flag.target_countries ?? [];
      return targets.length === 0 || targets.includes(country);
    });

    return json({ flags });
  } catch (err) {
    console.error("catalog-flags failed", err);
    return json({ error: "Unexpected flags failure" }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
