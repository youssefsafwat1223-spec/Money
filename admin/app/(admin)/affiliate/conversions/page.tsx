import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { HelpNote, PageHeader } from "@/components/ui/primitives";
import { ConversionsTable, type ConversionRow } from "./conversions-table";

/**
 * COUPONS Phase 3 — commission reporting.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * THIS IS THE ONLY PLACE COMMISSION IS EVER SHOWN, AND IT IS ADMIN-ONLY.
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * What a network pays us is our revenue, in our currency, under our contract. It
 * is not the user's money. The client status endpoint returns `pending` /
 * `confirmed` / `declined` and nothing else — it does not even SELECT the
 * commission columns — and the savings math has no parameter that could carry
 * one. Conflating the two would either inflate a user's savings with our revenue
 * or leak the rate card into the app.
 *
 * A conversion row carries no user, and its click carries none either. This page
 * shows what was earned, not who earned it for us — and cannot show the latter,
 * because nothing in the schema records it.
 */
export default async function ConversionsPage() {
  await requireAdmin();
  const supabase = await createAdminClient();

  const { data } = await supabase
    .from("affiliate_conversions")
    .select(
      "id, network_key, external_conversion_id, click_id, status, status_history, " +
        "order_amount_minor, order_currency, commission_amount_minor, commission_currency, " +
        "provider_discount_minor, provider_discount_currency, occurred_at, updated_at",
    )
    .order("updated_at", { ascending: false })
    .limit(200);

  const rows: ConversionRow[] = ((data ?? []) as unknown as Array<Record<string, unknown>>).map(
    (r) => ({
      id: r.id as string,
      network_key: r.network_key as string,
      external_conversion_id: r.external_conversion_id as string,
      correlated: r.click_id != null,
      status: r.status as string,
      history_length: Array.isArray(r.status_history) ? r.status_history.length : 0,
      order_amount_minor: (r.order_amount_minor as number | null) ?? null,
      order_currency: (r.order_currency as string | null) ?? null,
      commission_amount_minor: (r.commission_amount_minor as number | null) ?? null,
      commission_currency: (r.commission_currency as string | null) ?? null,
      provider_discount_minor: (r.provider_discount_minor as number | null) ?? null,
      provider_discount_currency: (r.provider_discount_currency as string | null) ?? null,
      updated_at: r.updated_at as string,
    }),
  );

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="عروض الشركاء"
        title="التحويلات والعمولة"
        description="ما أبلغت به الشبكات من عمليات بيع، وحالة كل منها."
      />
      <HelpNote>
        العمولة هي إيرادنا نحن، لا مبلغ وفّره المستخدم. لا تظهر العمولة في
        التطبيق إطلاقًا، ولا تدخل في أي رقم توفير. كذلك لا يحمل صف التحويل أي
        هوية مستخدم — لأن سجل النقرة نفسه لا يحملها.
      </HelpNote>
      <ConversionsTable rows={rows} />
    </div>
  );
}
