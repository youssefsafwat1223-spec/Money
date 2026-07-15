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
