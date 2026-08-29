import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { assertSafeSupabaseTarget } from "./lib/env-guard";

export async function middleware(request: NextRequest) {
  // Development-only: refuse to serve anything if this dev server is pointed at
  // a deployed project. No-op under NODE_ENV=production. See lib/env-guard.ts.
  assertSafeSupabaseTarget();

  let supabaseResponse = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() { return request.cookies.getAll(); },
        setAll(cookiesToSet: { name: string; value: string; options?: object }[]) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value),
          );
          supabaseResponse = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options as object),
          );
        },
      },
    },
  );

  const { data: { user } } = await supabase.auth.getUser();
  const path = request.nextUrl.pathname;
  const isLogin = path.startsWith("/login");
  const isNotAuthorized = path.startsWith("/not-authorized");

  if (!user && !isLogin && !isNotAuthorized) {
    return NextResponse.redirect(new URL("/login", request.url));
  }
  if (!user) return supabaseResponse;

  const { data: adminRow, error: adminError } = await supabase
    .from("admin_users")
    .select("id")
    .eq("id", user.id)
    .maybeSingle();
  const isAdmin = !adminError && adminRow != null;

  if (!isAdmin && !isNotAuthorized) {
    return NextResponse.redirect(new URL("/not-authorized", request.url));
  }
  if (isAdmin && (isLogin || isNotAuthorized)) {
    return NextResponse.redirect(new URL("/dashboard", request.url));
  }

  return supabaseResponse;
}

export const config = {
  // Static brand assets and fonts under /public must be excluded, otherwise the
  // middleware 307s them to /login and the sign-in screen cannot render its own
  // logo. Only extension-suffixed static files are exempted — every Admin page
  // and every /api route still passes through the guard above unchanged.
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|webp|gif|ico|ttf|woff|woff2)$).*)",
  ],
};
