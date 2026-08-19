// Referral & Ads Phase R2 — manual entitlement EXTEND (spec §7).
// Verb-only export. Same concurrency-safe UPSERT and stacking rule as referral
// rewards (no special path). Action pinned to 'extend'.
import { NextRequest } from "next/server";
import { runEntitlementMutation } from "@/lib/referral-rpc";

export async function POST(req: NextRequest) {
  return runEntitlementMutation(req, ["extend"]);
}
