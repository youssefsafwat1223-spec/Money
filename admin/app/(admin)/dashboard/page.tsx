import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { fmt } from "@/lib/utils";
import { Users, Building2, Code2, Megaphone, ToggleLeft, Tag, UserCheck, UserPlus } from "lucide-react";

type UserStats = {
  total: number;
  new_this_month: number;
  active_7d: number;
  daily_signups: { label: string; day: string; count: number }[];
};

type CatalogStats = {
  banks: number;
  parsers: number;
  parsers_passed: number;
  parsers_pending: number;
  categories: number;
  active_flags: number;
  active_announcements: number;
};

async function getStats(): Promise<{ users: UserStats; catalog: CatalogStats }> {
  await requireAdmin();
  const supabase = await createAdminClient();

  // The RPC is service-role only; requireAdmin above is the authorization gate.
  const { data: userStats, error: userError } = await supabase
    .rpc("get_user_stats");

  if (userError) {
    console.error("get_user_stats RPC failed:", userError.message);
  }

  const users: UserStats = userStats ?? {
    total: 0,
    new_this_month: 0,
    active_7d: 0,
    daily_signups: [],
  };

  // Catalog stats — all readable by anon/authenticated via RLS.
  const [banks, parsersAll, categories, flagsAll, announcementsAll] =
    await Promise.all([
      supabase.from("banks").select("id", { count: "exact", head: true }),
      supabase.from("sms_parsers").select("id, validation_status"),
      supabase.from("categories").select("id", { count: "exact", head: true }),
      supabase.from("feature_flags").select("id, is_active"),
      supabase.from("announcements").select("id, is_active"),
    ]);

  const parsers = parsersAll.data ?? [];
  const flags = flagsAll.data ?? [];
  const announcements = announcementsAll.data ?? [];

  const catalog: CatalogStats = {
    banks: banks.count ?? 0,
    parsers: parsers.length,
    parsers_passed: parsers.filter(p => p.validation_status === "passed").length,
    parsers_pending: parsers.filter(p => p.validation_status === "pending").length,
    categories: categories.count ?? 0,
    active_flags: flags.filter(f => f.is_active).length,
    active_announcements: announcements.filter(a => a.is_active).length,
  };

  return { users, catalog };
}

export default async function DashboardPage() {
  const { users, catalog } = await getStats();

  const userCards = [
    { label: "Total Users",    value: fmt(users.total),          sub: "all time",        icon: Users,      color: "bg-blue-50 text-blue-600" },
    { label: "New This Month", value: fmt(users.new_this_month), sub: "signed up",       icon: UserPlus,   color: "bg-green-50 text-green-600" },
    { label: "Active (7d)",    value: fmt(users.active_7d),      sub: "opened app",      icon: UserCheck,  color: "bg-indigo-50 text-indigo-600" },
  ];

  const catalogCards = [
    { label: "Banks",         value: fmt(catalog.banks),              sub: "in catalog",   icon: Building2,  color: "bg-cyan-50 text-cyan-600" },
    { label: "Parsers",       value: fmt(catalog.parsers),            sub: `${catalog.parsers_pending} pending`, icon: Code2, color: "bg-amber-50 text-amber-600" },
    { label: "Feature Flags", value: fmt(catalog.active_flags),       sub: "active",       icon: ToggleLeft, color: "bg-purple-50 text-purple-600" },
    { label: "Categories",    value: fmt(catalog.categories),         sub: "in catalog",   icon: Tag,        color: "bg-teal-50 text-teal-600" },
    { label: "Announcements", value: fmt(catalog.active_announcements), sub: "live",       icon: Megaphone,  color: "bg-rose-50 text-rose-600" },
  ];

  const daily = users.daily_signups ?? [];
  const maxDaily = Math.max(...daily.map(d => d.count), 1);

  const parsersFailed = catalog.parsers - catalog.parsers_passed - catalog.parsers_pending;

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-semibold text-gray-900">Dashboard</h1>
        <p className="text-sm text-gray-500 mt-1">Mali — users & catalog overview</p>
      </div>

      {/* User stats */}
      <section className="space-y-3">
        <h2 className="text-xs font-semibold uppercase tracking-wide text-gray-400">Users</h2>
        <div className="grid grid-cols-3 gap-4">
          {userCards.map(card => (
            <div key={card.label} className="bg-white rounded-xl border border-gray-100 p-5 flex items-start gap-4">
              <div className={`p-2.5 rounded-lg ${card.color}`}>
                <card.icon size={18} />
              </div>
              <div>
                <p className="text-2xl font-semibold text-gray-900">{card.value}</p>
                <p className="text-sm text-gray-500">{card.label}</p>
                <p className="text-xs text-gray-400 mt-0.5">{card.sub}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Daily signups chart */}
      <div className="bg-white rounded-xl border border-gray-100 p-5">
        <h2 className="text-sm font-medium text-gray-700 mb-4">Daily Signups — last 7 days</h2>
        {daily.length === 0 ? (
          <p className="text-xs text-gray-400 py-8 text-center">No signup data yet</p>
        ) : (
          <div className="flex items-end gap-2 h-28">
            {daily.map(d => (
              <div key={d.label} className="flex-1 flex flex-col items-center gap-1.5">
                <span className="text-xs text-gray-500 font-medium">
                  {d.count > 0 ? d.count : ""}
                </span>
                <div
                  className="w-full bg-brand-500 rounded-t-sm transition-all"
                  style={{
                    height: `${(d.count / maxDaily) * 80}px`,
                    minHeight: d.count > 0 ? "4px" : "0",
                  }}
                />
                <span className="text-[10px] text-gray-400">{d.label}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Catalog stats */}
      <section className="space-y-3">
        <h2 className="text-xs font-semibold uppercase tracking-wide text-gray-400">Catalog</h2>
        <div className="grid grid-cols-3 lg:grid-cols-5 gap-4">
          {catalogCards.map(card => (
            <div key={card.label} className="bg-white rounded-xl border border-gray-100 p-4 flex items-start gap-3">
              <div className={`p-2 rounded-lg ${card.color}`}>
                <card.icon size={16} />
              </div>
              <div>
                <p className="text-xl font-semibold text-gray-900">{card.value}</p>
                <p className="text-xs text-gray-500">{card.label}</p>
                <p className="text-[10px] text-gray-400 mt-0.5">{card.sub}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Parser health */}
      <div className="bg-white rounded-xl border border-gray-100 p-5">
        <h2 className="text-sm font-medium text-gray-700 mb-4">Parser Validation Health</h2>
        <div className="space-y-3">
          {[
            { label: "Passed",  count: catalog.parsers_passed,  color: "bg-green-500" },
            { label: "Pending", count: catalog.parsers_pending,  color: "bg-amber-400" },
            { label: "Failed",  count: parsersFailed < 0 ? 0 : parsersFailed, color: "bg-red-400" },
          ].map(row => (
            <div key={row.label} className="flex items-center gap-3">
              <div className={`w-2 h-2 rounded-full ${row.color}`} />
              <span className="text-sm text-gray-600 w-16">{row.label}</span>
              <span className="text-sm font-medium text-gray-900 w-8">{row.count}</span>
              <div className="flex-1 h-1.5 bg-gray-100 rounded-full overflow-hidden">
                <div
                  className={`h-full rounded-full ${row.color}`}
                  style={{ width: `${(row.count / (catalog.parsers || 1)) * 100}%` }}
                />
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
