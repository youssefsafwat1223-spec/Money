import Link from "next/link";
import { Plus } from "lucide-react";
import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { ErrorState, HelpNote, PageHeader } from "@/components/ui/primitives";
import { fmt } from "@/lib/utils";
import { BanksTable, type BankRow } from "./banks-table";

export default async function BanksPage() {
  await requireAdmin();
  const supabase = await createAdminClient();
  const { data: banks, error } = await supabase
    .from("banks")
    .select("id, name_ar, name_en, short_code, country_code, is_active, sort_order, sms_senders")
    .order("sort_order", { ascending: true });

  const rows: BankRow[] = (banks ?? []).map((bank) => ({
    id: bank.id as string,
    name_ar: bank.name_ar as string | null,
    name_en: bank.name_en as string | null,
    short_code: bank.short_code as string | null,
    country_code: bank.country_code as string | null,
    is_active: Boolean(bank.is_active),
    senders:
      typeof bank.sms_senders === "string"
        ? (JSON.parse(bank.sms_senders) as string[])
        : ((bank.sms_senders ?? []) as string[]),
  }));

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="كتالوج البنوك والرسائل"
        title="البنوك"
        description={`${fmt(rows.length)} بنك في الكتالوج. التطبيق يستخدم هذه القائمة ليعرف من أي بنك جاءت الرسالة.`}
        action={
          <Link
            href="/banks/new"
            className="inline-flex items-center gap-2 rounded-field bg-brand-700 px-4 py-2.5 text-sm font-medium text-white transition-colors hover:bg-brand-800"
          >
            <Plus size={15} /> إضافة بنك
          </Link>
        }
      />

      <HelpNote>
        «أرقام المُرسِل» هي الأسماء أو الأرقام التي تصل منها رسائل البنك. إذا لم يكن رقم المُرسِل
        مضافًا هنا، لن يتعرّف التطبيق على رسائل هذا البنك.
      </HelpNote>

      {error ? (
        <ErrorState title="تعذّر تحميل قائمة البنوك" detail={error.message} />
      ) : (
        <BanksTable banks={rows} />
      )}
    </div>
  );
}
