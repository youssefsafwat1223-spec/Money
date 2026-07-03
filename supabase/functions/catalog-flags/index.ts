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
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!supabaseUrl || !serviceKey || !anonKey) {
      return json({ error: "Supabase environment is not configured" }, 500);
    }

    // Fetch ALL flags (active + inactive) so per-user overrides can re-enable
    // flags that are globally OFF (useful for staged TestFlight rollouts).
    const adminClient = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: allFlags, error: flagsError } = await adminClient
      .from("feature_flags")
      .select(
        "key, value_type, value, rollout_percent, target_countries, is_active",
      );
    if (flagsError) return json({ error: flagsError.message }, 500);

    // Build a mutable map keyed by flag key so overrides can patch in-place.
    const flagMap = new Map<string, Record<string, unknown>>(
      (allFlags ?? []).map((f) => [f.key as string, { ...f }]),
    );

    // Apply per-user overrides when the request carries a valid user JWT.
    // Guest requests (no Authorization header) skip this block entirely.
    const authHeader = req.headers.get("authorization");
    if (authHeader?.startsWith("Bearer ")) {
      // Use anon key + user JWT so Supabase enforces RLS on the overrides table
      // (only the authenticated user's own rows are returned).
      const userClient = createClient(supabaseUrl, anonKey, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { authorization: authHeader } },
      });
      const { data: overrides } = await userClient
        .from("feature_flag_overrides")
        .select("key, enabled");
      for (const override of overrides ?? []) {
        const flag = flagMap.get(override.key as string);
        if (!flag) continue; // unknown key — skip
        if (override.enabled) {
          flag.is_active = true;
          flag.rollout_percent = 100;
          if (flag.value_type === "boolean") flag.value = "true";
        } else {
          flag.is_active = false;
          flag.rollout_percent = 0;
        }
      }
    }

    // Filter to effectively active flags then apply country filter.
    const flags = [...flagMap.values()].filter((flag) => {
      if (!flag.is_active) return false;
      if (!country) return true;
      const targets = (flag.target_countries as string[]) ?? [];
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
