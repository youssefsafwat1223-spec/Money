// Referral & Ads Phase R2 — manual entitlement REVOKE / SHORTEN (spec §7).
// Verb-only export. A separate, explicit action from fraud reversal, with a
// required reason. Accepts action ∈ {revoke, shorten}: revoke carries no
// duration; shorten carries a positive duration (days to cut). Grant/extend are
// rejected here. Consumed historical ad-free time is never rewritten.
import { NextRequest } from "next/server";
import { runEntitlementMutation } from "@/lib/referral-rpc";

export async function POST(req: NextRequest) {
  return runEntitlementMutation(req, ["revoke", "shorten"]);
}
