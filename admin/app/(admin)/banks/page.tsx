import Link from "next/link";
import { createAdminClient } from "@/lib/supabase-server";
import { Plus, Pencil } from "lucide-react";

export default async function BanksPage() {
  const supabase = await createAdminClient();
  const { data: banks } = await supabase
    .from("banks")
    .select("id, name_ar, name_en, short_code, country_code, is_active, sort_order, sms_senders")
    .order("sort_order", { ascending: true });

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900">Banks</h1>
          <p className="text-sm text-gray-500 mt-1">{banks?.length ?? 0} banks in catalog</p>
        </div>
        <Link
          href="/banks/new"
          className="flex items-center gap-2 px-4 py-2 bg-brand-500 text-white rounded-lg text-sm font-medium hover:bg-brand-600 transition-colors"
        >
          <Plus size={16} /> Add Bank
        </Link>
      </div>

      <div className="bg-white rounded-xl border border-gray-100 overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-gray-100 bg-gray-50">
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Bank</th>
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Code</th>
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Country</th>
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">SMS Senders</th>
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Status</th>
              <th className="px-4 py-3" />
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-50">
            {(banks ?? []).map(bank => {
              const senders: string[] = typeof bank.sms_senders === "string"
                ? JSON.parse(bank.sms_senders)
                : bank.sms_senders ?? [];
              return (
                <tr key={bank.id} className="hover:bg-gray-50">
                  <td className="px-4 py-3">
                    <div className="font-medium text-gray-900">{bank.name_ar}</div>
                    <div className="text-gray-400 text-xs">{bank.name_en}</div>
                  </td>
                  <td className="px-4 py-3 font-mono text-gray-500">{bank.short_code}</td>
                  <td className="px-4 py-3 text-gray-500">{bank.country_code}</td>
                  <td className="px-4 py-3">
                    <div className="flex flex-wrap gap-1">
                      {senders.slice(0, 3).map(s => (
                        <span key={s} className="px-1.5 py-0.5 bg-gray-100 text-gray-600 rounded text-xs font-mono">{s}</span>
                      ))}
                      {senders.length > 3 && (
                        <span className="px-1.5 py-0.5 bg-gray-100 text-gray-400 rounded text-xs">+{senders.length - 3}</span>
                      )}
                    </div>
                  </td>
                  <td className="px-4 py-3">
                    <span className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${bank.is_active ? "bg-green-100 text-green-700" : "bg-gray-100 text-gray-500"}`}>
                      {bank.is_active ? "Active" : "Inactive"}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <Link href={`/banks/${bank.id}`} className="inline-flex items-center gap-1 text-gray-400 hover:text-brand-500 transition-colors">
                      <Pencil size={14} />
                    </Link>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
