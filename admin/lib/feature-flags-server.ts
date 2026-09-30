import { createAdminClient } from "@/lib/supabase-server";
import type { ChangeRequest, FlagRow } from "@/lib/flag-registry";

type Admin = Awaited<ReturnType<typeof createAdminClient>>;

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Rows for the keys a request touches (service role, server only). */
export async function loadFlagRows(supabase: Admin, changes: ChangeRequest[]) {
  const keys = changes.map((c) => c?.key).filter((k): k is string => typeof k === "string");
  const { data, error } = await supabase.from("feature_flags").select("*").in("key", keys);
  return { rows: (data ?? []) as FlagRow[], error };
}

/**
 * Probe for migration 0101 (sender_bank_mappings.accepted_by). The RPC is the
 * authority and blocks enabling ai_sender_mapping_auto without it; this lets
 * /preview say so before the operator reaches confirmation.
 */
export async function acceptedByColumnExists(supabase: Admin): Promise<boolean> {
  const { error } = await supabase.from("sender_bank_mappings").select("accepted_by").limit(0);
  return !error;
}

/** Maps an RPC SQLSTATE (see supabase/deferred/0102) to the HTTP contract. */
export function rpcErrorStatus(code: string | undefined): number {
  switch (code) {
    case "P0409":
      return 409; // stale_flag / flag_exists -> refresh prompt
    case "P0404":
      return 404;
    case "P0403":
      return 403;
    case "P0422":
      return 422;
    default:
      return 500;
  }
}
