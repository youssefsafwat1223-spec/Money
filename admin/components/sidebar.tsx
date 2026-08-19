"use client";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import {
  LayoutDashboard, Building2, Code2, Tag, ToggleLeft,
  Megaphone, LogOut, ChevronRight, FlaskConical, TicketPercent, Gift,
} from "lucide-react";
import { createClient } from "@/lib/supabase";
import { cn } from "@/lib/utils";

const NAV = [
  { href: "/dashboard",     label: "Dashboard",     icon: LayoutDashboard },
  { href: "/banks",         label: "Banks",         icon: Building2 },
  { href: "/parsers",       label: "Parsers",       icon: Code2 },
  { href: "/categories",    label: "Categories",    icon: Tag },
  { href: "/flags",         label: "Feature Flags", icon: ToggleLeft },
  { href: "/announcements", label: "Announcements", icon: Megaphone },
  { href: "/campaigns",     label: "Campaigns",     icon: Megaphone },
  { href: "/coupons",       label: "Offers",        icon: TicketPercent },
  { href: "/referrals",     label: "Referral & Ads", icon: Gift },
  { href: "/parser-lab",    label: "Parser Lab",    icon: FlaskConical },
];

export function Sidebar() {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();

  async function signOut() {
    await supabase.auth.signOut();
    router.push("/login");
    router.refresh();
  }

  return (
    <aside className="fixed inset-y-0 left-0 w-60 bg-brand-900 flex flex-col z-10">
      {/* Logo */}
      <div className="h-16 flex items-center px-5 border-b border-white/10">
        <div className="flex items-center gap-3">
          <div className="w-8 h-8 bg-brand-500 rounded-lg flex items-center justify-center">
            <span className="text-white font-bold text-sm">M</span>
          </div>
          <span className="text-white font-semibold">Mali Admin</span>
        </div>
      </div>

      {/* Nav */}
      <nav className="flex-1 px-3 py-4 space-y-0.5 overflow-y-auto scrollbar-thin">
        {NAV.map(({ href, label, icon: Icon }) => {
          const active = pathname === href || pathname.startsWith(href + "/");
          return (
            <Link
              key={href}
              href={href}
              className={cn(
                "flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm transition-colors group",
                active
                  ? "bg-brand-500 text-white"
                  : "text-white/60 hover:text-white hover:bg-white/5",
              )}
            >
              <Icon size={16} />
              <span className="flex-1">{label}</span>
              {active && <ChevronRight size={14} className="opacity-50" />}
            </Link>
          );
        })}
      </nav>

      {/* Sign out */}
      <div className="p-3 border-t border-white/10">
        <button
          onClick={signOut}
          className="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm text-white/60 hover:text-white hover:bg-white/5 transition-colors"
        >
          <LogOut size={16} />
          <span>Sign out</span>
        </button>
      </div>
    </aside>
  );
}
