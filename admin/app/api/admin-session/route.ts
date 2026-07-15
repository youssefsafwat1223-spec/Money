import { NextResponse } from "next/server";
import { AdminAuthError, requireAdmin } from "@/lib/auth-guard";

export async function GET() {
  try {
    const user = await requireAdmin();
    return NextResponse.json({ authorized: true, userId: user.id });
  } catch (error) {
    const status = error instanceof AdminAuthError && error.code === "unauthenticated"
      ? 401
      : 403;
    return NextResponse.json({ authorized: false }, { status });
  }
}
