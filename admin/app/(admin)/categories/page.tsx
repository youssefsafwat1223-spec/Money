import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { ErrorState, HelpNote, PageHeader } from "@/components/ui/primitives";
import { fmt } from "@/lib/utils";
import { CategoriesTable, type CategoryRow } from "./categories-table";

export default async function CategoriesPage() {
  await requireAdmin();
  const supabase = await createAdminClient();
  const { data: cats, error } = await supabase
    .from("categories")
    .select("id, key, name_ar, name_en, type, is_active, sort_order, icon, color_hex, parent_key")
    .order("sort_order", { ascending: true });

  const rows: CategoryRow[] = (cats ?? []).map((c) => ({
    id: c.id as string,
    key: c.key as string,
    name_ar: c.name_ar as string | null,
    name_en: c.name_en as string | null,
    type: (c.type as string) ?? "expense",
    is_active: Boolean(c.is_active),
    color_hex: c.color_hex as string | null,
    parent_key: c.parent_key as string | null,
  }));

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="كتالوج البنوك والرسائل"
        title="فئات المصروفات"
        description={`${fmt(rows.length)} فئة. هذه هي الفئات التي تُصنَّف عليها عمليات المستخدمين داخل التطبيق.`}
      />

      {/*
        Deliberately read-only: there is no create/edit route for categories in
        this Admin, and inventing a form would imply a capability that does not
        exist. The note below says so plainly instead of showing a dead button.
      */}
      {/*
        UX-019 — the note used to attribute the key dependency to "قواعد قراءة
        الرسائل" (`sms_parsers`). That table has no category column at all, so
        the stated reason for not editing a key was simply not the real one — an
        operator acting on it would have been reasoning from a false model.

        The actual dependents are the tables that STORE a category key as plain
        TEXT with no foreign key: users' transactions, their budgets, and the
        merchant→category keyword map (0006_merchant_keywords.sql). Because
        there is no FK, renaming a key silently orphans those rows instead of
        failing loudly — which is precisely why it must not be edited, and a
        sharper reason than the one it replaces.
      */}
      <HelpNote>
        هذه القائمة للاطّلاع فقط في هذه اللوحة. «المفتاح الثابت» مخزَّن كنص داخل عمليات المستخدمين
        وميزانياتهم وجدول كلمات التجّار، بدون رابط يمنع كسره —{" "}
        <strong>تغييره لا يفشل، بل يفصل البيانات القديمة عن فئتها بصمت</strong>، ولذلك لا يُعدَّل من
        هنا.
      </HelpNote>

      {error ? (
        <ErrorState title="تعذّر تحميل الفئات" detail={error.message} />
      ) : (
        <CategoriesTable categories={rows} />
      )}
    </div>
  );
}
