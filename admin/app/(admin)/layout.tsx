import { redirect } from "next/navigation";
import { AdminAuthError, requireAdmin } from "@/lib/auth-guard";
import { Sidebar } from "@/components/sidebar";

export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  try {
    await requireAdmin();
  } catch (error) {
    if (error instanceof AdminAuthError && error.code === "unauthenticated") {
      redirect("/login");
    }
    redirect("/not-authorized");
  }

  return (
    <div className="flex min-h-screen">
      <Sidebar />
      <main className="flex-1 ml-60 min-h-screen">
        <div className="p-8">{children}</div>
      </main>
    </div>
  );
}
