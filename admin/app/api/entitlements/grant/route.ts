// Referral & Ads Phase R2 — manual entitlement GRANT (spec §7).
// Verb-only export. Action pinned to 'grant'; requires a positive duration and
// a bounded plain-text reason (validated). Idempotent via the client-minted
// operation_id enforced by admin_mutate_entitlement.
import { NextRequest } from "next/server";
import { runEntitlementMutation } from "@/lib/referral-rpc";

export async function POST(req: NextRequest) {
  return runEntitlementMutation(req, ["grant"]);
}
