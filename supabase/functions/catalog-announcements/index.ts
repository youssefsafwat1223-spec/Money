import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-app-version',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const appVersion = req.headers.get('x-app-version') ?? '0.0.0';
  console.log(`catalog-announcements requested by app version: ${appVersion}`);

  try {
    const url = new URL(req.url);
    const country = url.searchParams.get('country')?.trim().toUpperCase();

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ??
      Deno.env.get('SUPABASE_ANON_KEY');
    if (!supabaseUrl || !serviceKey) {
      return json({ error: 'Supabase environment is not configured' }, 500);
    }

    const client = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const now = new Date().toISOString();

    const { data, error } = await client
      .from('announcements')
      .select('*')
      .eq('is_active', true)
      .lte('valid_from', now)
      .or(`valid_until.is.null,valid_until.gte.${now}`)
      .order('priority', { ascending: false });

    if (error) return json({ error: error.message }, 500);

    const announcements = (data ?? []).filter((a) => {
      // Country filter: include if target_countries is empty or matches.
      if (country) {
        const targets: string[] = a.target_countries ?? [];
        if (targets.length > 0 && !targets.includes(country)) return false;
      }

      // App version filter: exclude if current app version is out of range.
      if (a.min_app_version && !versionGte(appVersion, a.min_app_version)) {
        return false;
      }
      if (a.max_app_version && !versionLte(appVersion, a.max_app_version)) {
        return false;
      }

      return true;
    });

    return json({ announcements });
  } catch (err) {
    console.error('catalog-announcements failed', err);
    return json({ error: 'Unexpected announcements failure' }, 500);
  }
});

/** Compare semver strings. Returns true if a >= b. */
function versionGte(a: string, b: string): boolean {
  return compareSemver(a, b) >= 0;
}

function versionLte(a: string, b: string): boolean {
  return compareSemver(a, b) <= 0;
}

function compareSemver(a: string, b: string): number {
  const pa = parseSemver(a);
  const pb = parseSemver(b);
  for (let i = 0; i < 3; i++) {
    if (pa[i] !== pb[i]) return pa[i] - pb[i];
  }
  return 0;
}

function parseSemver(v: string): [number, number, number] {
  const parts = (v ?? '0.0.0').replace(/[^0-9.]/g, '').split('.').map(Number);
  return [parts[0] ?? 0, parts[1] ?? 0, parts[2] ?? 0];
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
