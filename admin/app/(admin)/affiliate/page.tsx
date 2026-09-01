import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { HelpNote, PageHeader } from "@/components/ui/primitives";
import { AffiliateReview, type RunRow, type SourceRow } from "./affiliate-review";

/**
 * COUPONS Phase 2 — the affiliate review queue and the ingestion ledger.
 *
 * Nothing a provider sends reaches a user without passing through this page. A
 * partner feed is an untrusted input — expired offers, dead links, wrong
 * currencies, copy written for a different market — and the ingestion worker
 * deliberately has no code path that can publish. This is the other half of that
 * guarantee.
 *
 * The run ledger sits alongside on purpose. Without it, an ingestion that has
 * been failing for three weeks looks exactly like a provider with nothing new.
 */
export default async function AffiliatePage() {
  await requireAdmin();
  const supabase = await createAdminClient();

  const [{ data: sources }, { data: runs }] = await Promise.all([
    supabase
      .from("affiliate_offer_sources")
      .select(
        "id, program_id, coupon_id, external_offer_id, normalized, provider_status, review_state, review_note, last_seen_at, affiliate_programs(merchant_id, external_program_id)",
      )
      .order("last_seen_at", { ascending: false })
      .limit(200),
    supabase
      .from("affiliate_ingestion_runs")
      .select(
        "id, network_key, kind, status, fetched_count, new_count, updated_count, rejected_count, safe_error_code, started_at, finished_at",
      )
      .order("started_at", { ascending: false })
      .limit(20),
  ]);

  const sourceRows: SourceRow[] = ((sources ?? []) as unknown as Array<Record<string, unknown>>).map(
    (s) => {
      const program = s.affiliate_programs as
        | { merchant_id: string | null; external_program_id: string }
        | null;
      const n = (s.normalized ?? {}) as Record<string, unknown>;
      return {
        id: s.id as string,
        external_offer_id: s.external_offer_id as string,
        external_program_id: program?.external_program_id ?? "—",
        merchant_bound: Boolean(program?.merchant_id),
        title_ar: (n.titleAr as string) ?? "",
        description_ar: (n.descriptionAr as string) ?? "",
        benefit_type: (n.benefitType as string | null) ?? null,
        discount_bps: (n.discountBps as number | null) ?? null,
        benefit_currency: (n.benefitCurrency as string | null) ?? null,
        markets: (n.markets as string[] | null) ?? [],
        provider_status: s.provider_status as string,
        review_state: s.review_state as string,
        review_note: (s.review_note as string | null) ?? null,
        coupon_id: (s.coupon_id as string | null) ?? null,
        last_seen_at: s.last_seen_at as string,
      };
    },
  );

  const runRows: RunRow[] = ((runs ?? []) as unknown as Array<Record<string, unknown>>).map((r) => ({
    id: r.id as string,
    network_key: r.network_key as string,
    kind: r.kind as string,
    status: r.status as string,
    fetched_count: (r.fetched_count as number) ?? 0,
    new_count: (r.new_count as number) ?? 0,
    updated_count: (r.updated_count as number) ?? 0,
    rejected_count: (r.rejected_count as number) ?? 0,
    safe_error_code: (r.safe_error_code as string | null) ?? null,
    started_at: r.started_at as string,
    finished_at: (r.finished_at as string | null) ?? null,
  }));

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="كتالوج العروض"
        title="عروض الشركاء الواردة"
        description="عروض تصل من شبكات الأفلييت. لا يصل أي عرض للمستخدمين قبل نشره يدويًا من هنا."
      />

      <HelpNote>
        العرض المنشور من هنا يبدأ <strong>غير مفعّل</strong> و
        <strong>غير مُتحقَّق منه</strong>. فعّله من شاشة العروض بعد أن ترى شكل
        البطاقة فعليًا — نصوص المزوّدين كثيرًا ما تكون بطول أو بأسلوب غير مناسب،
        واكتشاف ذلك على بطاقة منشورة يكون متأخرًا. وكون المزوّد ذكر العرض ليس
        تحققًا منه.
      </HelpNote>

      <AffiliateReview sources={sourceRows} runs={runRows} />
    </div>
  );
}
