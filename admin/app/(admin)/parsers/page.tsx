import Link from "next/link";
import { Plus } from "lucide-react";
import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { ErrorState, HelpNote, PageHeader } from "@/components/ui/primitives";
import { fmt } from "@/lib/utils";
import { ParsersTable, type ParserRow } from "./parsers-table";

export default async function ParsersPage() {
  await requireAdmin();
  const supabase = await createAdminClient();
  const { data: parsers, error } = await supabase
    .from("sms_parsers")
    .select(
      "id, bank_id, sender_pattern, message_pattern, transaction_type, language, priority, validation_status, is_active, banks(name_ar, short_code)",
    )
    .order("priority", { ascending: false });

  const rows: ParserRow[] = (parsers ?? []).map((p) => {
    const bank = (Array.isArray(p.banks) ? p.banks[0] : p.banks) as
      | { name_ar: string; short_code: string }
      | null;
    return {
      id: p.id as string,
      bank_name: bank?.name_ar ?? null,
      bank_code: bank?.short_code ?? null,
      sender_pattern: p.sender_pattern as string | null,
      message_pattern: p.message_pattern as string | null,
      transaction_type: p.transaction_type as string | null,
      language: p.language as string | null,
      priority: p.priority as number | null,
      validation_status: (p.validation_status as string) ?? "pending",
      is_active: Boolean(p.is_active),
    };
  });

  const passed = rows.filter((r) => r.validation_status === "passed").length;

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="كتالوج البنوك والرسائل"
        title="قواعد قراءة الرسائل"
        description={`${fmt(rows.length)} قاعدة، منها ${fmt(passed)} جاهزة للاستخدام في التطبيق.`}
        action={
          <Link
            href="/parsers/new"
            className="inline-flex items-center gap-2 rounded-field bg-brand-700 px-4 py-2.5 text-sm font-medium text-white transition-colors hover:bg-brand-800"
          >
            <Plus size={15} /> إضافة قاعدة
          </Link>
        }
      />

      <HelpNote>
        القاعدة تصف شكل رسالة البنك حتى يستخرج التطبيق منها المبلغ والتاجر والتاريخ.{" "}
        <strong>القاعدة التي لم تجتز الفحص لا تصل إلى المستخدمين إطلاقًا</strong>، حتى لو كانت
        مفعّلة — افحصها من صفحة تعديل القاعدة أولًا.
      </HelpNote>

      {error ? (
        <ErrorState title="تعذّر تحميل قواعد القراءة" detail={error.message} />
      ) : (
        <ParsersTable parsers={rows} />
      )}
    </div>
  );
}
