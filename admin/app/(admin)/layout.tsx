import { redirect } from "next/navigation";
import { AdminAuthError, requireAdmin } from "@/lib/auth-guard";
import { Sidebar } from "@/components/sidebar";

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  // Route protection is unchanged: the server guard decides, not the UI.
  let email: string | null = null;
  try {
    const user = await requireAdmin();
    email = user.email ?? null;
  } catch (error) {
    if (error instanceof AdminAuthError && error.code === "unauthenticated") {
      redirect("/login");
    }
    redirect("/not-authorized");
  }

  return (
    <div className="min-h-screen">
      <Sidebar adminEmail={email} />
      <main className="min-h-screen ms-[252px]">
        <div className="mx-auto max-w-[1400px] px-7 py-7 2xl:px-10">{children}</div>
      </main>
    </div>
  );
}
