"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { ChevronRight, LogOut } from "lucide-react";
import { createClient } from "@/lib/supabase";
import { NAV } from "@/lib/nav";
import { cn } from "@/lib/utils";

export function Sidebar({ adminEmail }: { adminEmail?: string | null }) {
  const pathname = usePathname();
  const router = useRouter();

  async function signOut() {
    await createClient().auth.signOut();
    router.push("/login");
    router.refresh();
  }

  return (
    <aside className="fixed inset-y-0 start-0 z-20 flex w-[252px] flex-col bg-gradient-to-b from-brand-deep to-brand-900">
      {/* Brand — the official Qirsh coin, not a placeholder letter mark. */}
      <div className="flex h-[68px] items-center gap-3 border-b border-white/10 px-5">
        <Image
          src="/brand/qirsh-coin.png"
          alt="قِرش"
          width={36}
          height={36}
          className="shrink-0 drop-shadow"
          priority
        />
        <div className="min-w-0 leading-tight">
          <p className="text-[15px] font-semibold text-white">قِرش</p>
          <p className="text-micro text-white/55">لوحة الإدارة</p>
        </div>
      </div>

      {/* Grouped navigation (registry: lib/nav.ts) */}
      <nav className="scrollbar-thin flex-1 overflow-y-auto px-3 py-4">
        {NAV.map(({ group, items }) => (
          <div key={group} className="mb-5 last:mb-0">
            <p className="mb-1.5 px-3 text-micro font-semibold tracking-wide text-white/40">
              {group}
            </p>
            <div className="space-y-0.5">
              {items.map(({ href, label, icon: Icon, description }) => {
                const active = pathname === href || pathname.startsWith(`${href}/`);
                return (
                  <Link
                    key={href}
                    href={href}
                    title={description}
                    aria-current={active ? "page" : undefined}
                    className={cn(
                      "group flex items-center gap-2.5 rounded-field px-3 py-2.5 text-sm transition-colors",
                      active
                        ? "bg-white/[0.14] font-medium text-white shadow-sm"
                        : "text-white/60 hover:bg-white/[0.07] hover:text-white",
                    )}
                  >
                    <Icon size={16} className="shrink-0" />
                    <span className="flex-1 truncate">{label}</span>
                    {/* Points at the content area — leftwards while the page is RTL. */}
                    <ChevronRight
                      size={14}
                      className={cn(
                        "flip-x shrink-0 transition-opacity",
                        active ? "opacity-60" : "opacity-0",
                      )}
                    />
                  </Link>
                );
              })}
            </div>
          </div>
        ))}
      </nav>

      {/* Signed-in identity + sign out */}
      <div className="border-t border-white/10 p-3">
        {adminEmail && (
          <p className="ltr mb-2 truncate px-3 text-micro text-white/45" title={adminEmail}>
            {adminEmail}
          </p>
        )}
        <button
          onClick={signOut}
          className="flex w-full items-center gap-2.5 rounded-field px-3 py-2.5 text-sm text-white/60 transition-colors hover:bg-white/[0.07] hover:text-white"
        >
          <LogOut size={16} className="flip-x" />
          <span>تسجيل الخروج</span>
        </button>
      </div>
    </aside>
  );
}
