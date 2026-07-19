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

  const appVersion = req.headers.get('x-app-version') ?? 'unknown';
  console.log(`catalog-versions requested by app version: ${appVersion}`);

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ??
      Deno.env.get('SUPABASE_ANON_KEY');
    if (!supabaseUrl || !serviceKey) {
      return json({ error: 'Supabase environment is not configured' }, 500);
    }

    const client = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await client
      .from('catalog_versions')
      .select('category, version');
    if (error) return json({ error: error.message }, 500);

    const versions: Record<string, number> = {};
    for (const row of data ?? []) {
      versions[row.category] = Number(row.version ?? 0);
    }
    return json(versions);
  } catch (error) {
    console.error('catalog-versions failed', error);
    return json({ error: 'Unexpected catalog version failure' }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json',
    },
  });
}
