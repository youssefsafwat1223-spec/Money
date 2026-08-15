import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase-server";

export class AdminAuthError extends Error {
  constructor(
    readonly code: "unauthenticated" | "not_authorized" | "authorization_unavailable",
  ) {
    super(code);
    this.name = "AdminAuthError";
  }
}

/** Verifies admin membership from the server-side Supabase session. */
export async function requireAdmin() {
  const supabase = await createClient();
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();
  if (userError || !user) throw new AdminAuthError("unauthenticated");

  const { data: adminRow, error: adminError } = await supabase
    .from("admin_users")
    .select("id")
    .eq("id", user.id)
    .maybeSingle();
  if (adminError) throw new AdminAuthError("authorization_unavailable");
  if (!adminRow) throw new AdminAuthError("not_authorized");
  return user;
}

/**
 * Maps an authorization failure to the HTTP contract every Admin API route
 * shares (Coupons Phase C3):
 *   unauthenticated                    -> 401
 *   authenticated but not an admin     -> 403
 *   auth/allowlist lookup unavailable  -> 503 (FAIL CLOSED, never "allow")
 * Anything that is not an AdminAuthError is rethrown to the caller.
 *
 * Admin rights are never inferred from an email address, a domain or any
 * client-supplied state — only from `public.admin_users` membership.
 */
export function adminAuthErrorResponse(error: unknown): NextResponse {
  if (error instanceof AdminAuthError) {
    if (error.code === "unauthenticated") {
      return NextResponse.json({ error: "unauthenticated" }, { status: 401 });
    }
    if (error.code === "not_authorized") {
      return NextResponse.json({ error: "not_authorized" }, { status: 403 });
    }
    return NextResponse.json({ error: "authorization_unavailable" }, { status: 503 });
  }
  throw error;
}
