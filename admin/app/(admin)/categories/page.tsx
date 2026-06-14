import Link from "next/link";
import { createAdminClient } from "@/lib/supabase-server";
import { Plus } from "lucide-react";

export default async function CategoriesPage() {
  const supabase = await createAdminClient();
  const { data: cats } = await supabase
    .from("categories")
    .select("id, key, name_ar, name_en, type, is_active, sort_order, icon, color_hex, parent_key")
    .order("sort_order", { ascending: true });

  const byType = (cats ?? []).reduce<Record<string, typeof cats>>((acc, c) => {
    const t = (c as { type: string }).type ?? "expense";
    acc[t] = [...(acc[t] ?? []), c];
    return acc;
  }, {});

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900">Categories</h1>
          <p className="text-sm text-gray-500 mt-1">{cats?.length ?? 0} categories • keys are stable and referenced by parsers</p>
        </div>
        <Link href="/categories/new"
          className="flex items-center gap-2 px-4 py-2 bg-brand-500 text-white rounded-lg text-sm font-medium hover:bg-brand-600 transition-colors">
          <Plus size={16} /> Add Category
        </Link>
      </div>

      {Object.entries(byType).map(([type, items]) => (
        <div key={type} className="bg-white rounded-xl border border-gray-100 overflow-hidden">
          <div className="px-4 py-3 border-b border-gray-50 bg-gray-50">
            <span className="text-xs font-semibold uppercase tracking-wide text-gray-500">{type}</span>
          </div>
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-gray-50">
                <th className="text-left px-4 py-2 text-xs font-medium text-gray-400">Name</th>
                <th className="text-left px-4 py-2 text-xs font-medium text-gray-400">Key</th>
                <th className="text-left px-4 py-2 text-xs font-medium text-gray-400">Icon</th>
                <th className="text-left px-4 py-2 text-xs font-medium text-gray-400">Parent</th>
                <th className="text-left px-4 py-2 text-xs font-medium text-gray-400">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50">
              {(items ?? []).map((c: unknown) => {
                const cat = c as { id: string; key: string; name_ar: string; name_en: string; icon: string; color_hex: string; parent_key: string | null; is_active: boolean };
                return (
                  <tr key={cat.id} className="hover:bg-gray-50">
                    <td className="px-4 py-2.5">
                      <div className="flex items-center gap-2">
                        <div className="w-5 h-5 rounded" style={{ background: cat.color_hex }} />
                        <div>
                          <div className="font-medium text-gray-900">{cat.name_ar}</div>
                          <div className="text-xs text-gray-400">{cat.name_en}</div>
                        </div>
                      </div>
                    </td>
                    <td className="px-4 py-2.5 font-mono text-xs text-gray-500">{cat.key}</td>
                    <td className="px-4 py-2.5 font-mono text-xs text-gray-500">{cat.icon}</td>
                    <td className="px-4 py-2.5 font-mono text-xs text-gray-400">{cat.parent_key ?? "—"}</td>
                    <td className="px-4 py-2.5">
                      <span className={`px-2 py-0.5 rounded-full text-xs ${cat.is_active ? "bg-green-100 text-green-700" : "bg-gray-100 text-gray-400"}`}>
                        {cat.is_active ? "Active" : "Inactive"}
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      ))}
    </div>
  );
}
