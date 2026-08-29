import Link from "next/link";
import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { fmt } from "@/lib/utils";
import { Card, PageHeader, SectionHeader, StatCard, StatusBadge } from "@/components/ui/primitives";
import { NAV } from "@/lib/nav";
import {
  Building2,
  Bell,
  CheckCircle2,
  ChevronRight,
  ListTree,
  ScanText,
  SlidersHorizontal,
  UserCheck,
  UserPlus,
  Users,
} from "lucide-react";

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
  parsers_failed: number;
  categories: number;
  active_flags: number;
  total_flags: number;
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
    // Each state is COUNTED, never derived by subtracting the others.
    parsers_passed: parsers.filter(p => p.validation_status === "passed").length,
    parsers_pending: parsers.filter(p => p.validation_status === "pending").length,
    parsers_failed: parsers.filter(p => p.validation_status === "failed").length,
    categories: categories.count ?? 0,
    active_flags: flags.filter(f => f.is_active).length,
    total_flags: flags.length,
    active_announcements: announcements.filter(a => a.is_active).length,
  };

  return { users, catalog };
}

/** Arabic day label from the timestamp the RPC already returns. */
function dayLabel(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return new Intl.DateTimeFormat("ar-EG-u-nu-latn", { day: "numeric", month: "short" }).format(d);
}

export default async function DashboardPage() {
  const { users, catalog } = await getStats();

  const daily = users.daily_signups ?? [];
  const maxDaily = Math.max(...daily.map(d => d.count), 1);
  const weekTotal = daily.reduce((sum, d) => sum + d.count, 0);

  // "Needs attention" is derived only from states that are actually counted.
  const attention = [
    catalog.parsers_failed > 0 && {
      tone: "danger" as const,
      title: `${fmt(catalog.parsers_failed)} قاعدة قراءة فشل فحصها`,
      body: "هذه القواعد لا تصل إلى التطبيق. راجعها وأعد تشغيل الفحص.",
      href: "/parsers",
      cta: "مراجعة القواعد",
    },
    catalog.parsers_pending > 0 && {
      tone: "warning" as const,
      title: `${fmt(catalog.parsers_pending)} قاعدة بانتظار الفحص`,
      body: "القاعدة لا تظهر للمستخدمين قبل أن تجتاز الفحص.",
      href: "/parsers",
      cta: "فتح القواعد",
    },
    catalog.active_announcements > 0 && {
      tone: "info" as const,
      title: `${fmt(catalog.active_announcements)} إعلان معروض الآن داخل التطبيق`,
      body: "تأكد أن محتواه ما زال صحيحًا وأن تاريخ انتهائه مضبوط.",
      href: "/announcements",
      cta: "عرض الإعلانات",
    },
  ].filter(Boolean) as {
    tone: "danger" | "warning" | "info";
    title: string;
    body: string;
    href: string;
    cta: string;
  }[];

  const parserStates = [
    { label: "اجتازت الفحص", count: catalog.parsers_passed, bar: "bg-success", tone: "success" as const },
    { label: "بانتظار الفحص", count: catalog.parsers_pending, bar: "bg-warning", tone: "warning" as const },
    { label: "فشل الفحص", count: catalog.parsers_failed, bar: "bg-danger", tone: "danger" as const },
  ];
  const parsersOther =
    catalog.parsers - catalog.parsers_passed - catalog.parsers_pending - catalog.parsers_failed;

  const catalogCards = [
    { label: "البنوك", value: fmt(catalog.banks), hint: "في الكتالوج", icon: Building2 },
    { label: "قواعد قراءة الرسائل", value: fmt(catalog.parsers), hint: `${fmt(catalog.parsers_passed)} جاهزة للتطبيق`, icon: ScanText },
    { label: "فئات المصروفات", value: fmt(catalog.categories), hint: "في الكتالوج", icon: ListTree },
    { label: "المزايا المفعّلة", value: fmt(catalog.active_flags), hint: `من ${fmt(catalog.total_flags)} ميزة`, icon: SlidersHorizontal },
    { label: "الإعلانات المعروضة", value: fmt(catalog.active_announcements), hint: "تظهر الآن داخل التطبيق", icon: Bell },
  ];

  return (
    <div className="space-y-7">
      <PageHeader
        eyebrow="نظرة عامة"
        title="الرئيسية"
        description="ملخّص سريع لما يحدث في قِرش الآن: نمو المستخدمين، ما يحتاج انتباهك، وحالة الكتالوج."
      />

      {/* ── 1. ما الذي يحدث؟ ─────────────────────────────────────────────── */}
      <section>
        <h2 className="mb-3 text-tiny font-semibold tracking-wide text-ink-faint">المستخدمون</h2>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <StatCard
            label="إجمالي المستخدمين"
            value={fmt(users.total)}
            hint="منذ إطلاق التطبيق"
            icon={Users}
            tone="brand"
          />
          <StatCard
            label="مستخدمون جدد هذا الشهر"
            value={fmt(users.new_this_month)}
            hint="سجّلوا منذ بداية الشهر الحالي"
            icon={UserPlus}
            tone="success"
          />
          <StatCard
            label="نشِطون خلال 7 أيام"
            value={fmt(users.active_7d)}
            hint="فتحوا التطبيق خلال آخر أسبوع"
            icon={UserCheck}
            tone="info"
          />
        </div>
      </section>

      <div className="grid gap-5 lg:grid-cols-[1.35fr_1fr]">
        {/* Signups — chronological, so in RTL the newest day sits on the left. */}
        <Card>
          <SectionHeader
            title="التسجيلات اليومية"
            description="عدد الحسابات الجديدة في كل يوم من آخر سبعة أيام."
            action={
              <span className="tnum rounded-full bg-brand-100 px-3 py-1 text-tiny font-medium text-brand-900">
                {fmt(weekTotal)} هذا الأسبوع
              </span>
            }
          />
          {daily.length === 0 ? (
            <p className="py-12 text-center text-sm text-ink-faint">
              لا توجد بيانات تسجيل بعد.
            </p>
          ) : (
            <div className="flex h-36 items-end gap-2.5">
              {daily.map((d) => (
                <div key={d.day} className="flex flex-1 flex-col items-center gap-1.5">
                  <span className="tnum text-micro font-medium text-ink-soft">
                    {d.count > 0 ? fmt(d.count) : ""}
                  </span>
                  <div
                    className="w-full rounded-t-md bg-gradient-to-t from-brand-700 to-brand-500"
                    style={{
                      height: `${(d.count / maxDaily) * 92}px`,
                      minHeight: d.count > 0 ? "5px" : "2px",
                      opacity: d.count > 0 ? 1 : 0.18,
                    }}
                    title={`${dayLabel(d.day)}: ${fmt(d.count)}`}
                  />
                  <span className="text-micro text-ink-faint">{dayLabel(d.day)}</span>
                </div>
              ))}
            </div>
          )}
        </Card>

        {/* ── 2. هل هناك ما يحتاج انتباهك؟ ──────────────────────────────── */}
        <Card>
          <SectionHeader
            title="يحتاج انتباهك"
            description="أمور مفتوحة يمكنك التصرف فيها الآن."
          />
          {attention.length === 0 ? (
            <div className="flex flex-col items-center py-8 text-center">
              <span className="mb-3 rounded-2xl bg-success-bg p-3 text-success">
                <CheckCircle2 size={20} />
              </span>
              <p className="text-sm font-medium text-ink">لا يوجد ما يحتاج انتباهك</p>
              <p className="mt-1 text-tiny text-ink-faint">
                كل قواعد القراءة مفحوصة ولا توجد إعلانات معلّقة.
              </p>
            </div>
          ) : (
            <ul className="space-y-2.5">
              {attention.map((a) => (
                <li key={a.title} className="rounded-field border border-hairline bg-raised/50 p-3.5">
                  <div className="mb-1.5">
                    <StatusBadge
                      label={a.tone === "danger" ? "يحتاج إصلاحًا" : a.tone === "warning" ? "قيد الانتظار" : "للعلم"}
                      tone={a.tone}
                    />
                  </div>
                  <p className="text-sm font-medium text-ink">{a.title}</p>
                  <p className="mt-1 text-tiny leading-relaxed text-ink-soft">{a.body}</p>
                  <Link
                    href={a.href}
                    className="mt-2 inline-flex items-center gap-1 text-tiny font-medium text-brand-700 hover:text-brand-800"
                  >
                    {a.cta}
                    <ChevronRight size={13} className="flip-x" />
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>

      {/* ── 4. هل يعمل النظام بشكل طبيعي؟ ────────────────────────────────── */}
      <section>
        <h2 className="mb-3 text-tiny font-semibold tracking-wide text-ink-faint">الكتالوج وحالة النظام</h2>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-5">
          {catalogCards.map((c) => (
            <StatCard key={c.label} label={c.label} value={c.value} hint={c.hint} icon={c.icon} tone="neutral" />
          ))}
        </div>
      </section>

      <Card>
        <SectionHeader
          title="حالة فحص قواعد القراءة"
          description="القاعدة التي لم تجتز الفحص لا تصل إلى التطبيق إطلاقًا، حتى لو كانت مفعّلة."
        />
        <div className="space-y-3">
          {parserStates.map((row) => (
            <div key={row.label} className="flex items-center gap-3">
              <span className="w-28 shrink-0 text-sm text-ink-soft">{row.label}</span>
              <span className="tnum w-10 shrink-0 text-sm font-medium text-ink">{fmt(row.count)}</span>
              <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-muted">
                <div
                  className={`h-full rounded-full ${row.bar}`}
                  style={{ width: `${(row.count / (catalog.parsers || 1)) * 100}%` }}
                />
              </div>
            </div>
          ))}
          {parsersOther > 0 && (
            <p className="text-micro text-ink-faint">
              {fmt(parsersOther)} قاعدة في حالة فحص أخرى غير الثلاث السابقة.
            </p>
          )}
        </div>
      </Card>

      {/* ── 3. ما الذي يمكنني إدارته؟ ────────────────────────────────────── */}
      <section>
        <h2 className="mb-3 text-tiny font-semibold tracking-wide text-ink-faint">إدارة سريعة</h2>
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {NAV.filter((g) => g.group !== "نظرة عامة").flatMap((g) => g.items).map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="group flex items-start gap-3 rounded-card border border-hairline bg-surface p-4 shadow-card transition-colors hover:border-brand-300 hover:bg-brand-50"
            >
              <span className="mt-0.5 shrink-0 rounded-field bg-brand-100 p-2 text-brand-900">
                <item.icon size={16} />
              </span>
              <span className="min-w-0">
                <span className="block text-sm font-medium text-ink">{item.label}</span>
                <span className="mt-0.5 block text-tiny leading-relaxed text-ink-faint">
                  {item.description}
                </span>
              </span>
              <ChevronRight
                size={15}
                className="flip-x mt-1 shrink-0 text-ink-faint opacity-0 transition-opacity group-hover:opacity-100"
              />
            </Link>
          ))}
        </div>
      </section>
    </div>
  );
}
