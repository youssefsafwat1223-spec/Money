import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { assertSafeSupabaseTarget } from "./env-guard";

export async function createClient() {
  // Development-only local-run safety; no-op in production. See lib/env-guard.ts.
  assertSafeSupabaseTarget();
  const cookieStore = await cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() { return cookieStore.getAll(); },
        setAll(cookiesToSet: { name: string; value: string; options?: object }[]) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options),
            );
          } catch {}
        },
      },
    },
  );
}

export async function createAdminClient() {
  // This factory sits directly in front of every privileged mutation, so the
  // guard is repeated here rather than relying on the middleware alone.
  assertSafeSupabaseTarget();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { cookies: { getAll: () => [], setAll: () => {} } },
  );
}
