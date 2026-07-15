import Link from "next/link";
import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { Plus, Pencil, CheckCircle, Clock, XCircle } from "lucide-react";

const statusIcon: Record<string, React.ReactNode> = {
  passed:  <CheckCircle size={14} className="text-green-500" />,
  pending: <Clock       size={14} className="text-amber-500" />,
  failed:  <XCircle     size={14} className="text-red-500" />,
};

const statusLabel: Record<string, string> = {
  passed: "bg-green-100 text-green-700",
  pending: "bg-amber-100 text-amber-700",
  failed: "bg-red-100 text-red-700",
};

export default async function ParsersPage() {
  await requireAdmin();
  const supabase = await createAdminClient();
  const { data: parsers } = await supabase
    .from("sms_parsers")
    .select("id, bank_id, sender_pattern, transaction_type, language, priority, validation_status, is_active, banks(name_ar, short_code)")
    .order("priority", { ascending: false });

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900">SMS Parsers</h1>
          <p className="text-sm text-gray-500 mt-1">{parsers?.length ?? 0} rules • only <span className="text-green-600 font-medium">passed</span> rules reach the app</p>
        </div>
        <Link href="/parsers/new"
          className="flex items-center gap-2 px-4 py-2 bg-brand-500 text-white rounded-lg text-sm font-medium hover:bg-brand-600 transition-colors">
          <Plus size={16} /> Add Parser
        </Link>
      </div>

      <div className="bg-white rounded-xl border border-gray-100 overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-gray-100 bg-gray-50">
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Bank</th>
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Sender Pattern</th>
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Type</th>
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Lang</th>
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Priority</th>
              <th className="text-left px-4 py-3 text-xs font-medium text-gray-500 uppercase tracking-wide">Validation</th>
              <th className="px-4 py-3" />
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-50">
            {(parsers ?? []).map(p => {
              const bank = Array.isArray(p.banks) ? p.banks[0] : p.banks as { name_ar: string; short_code: string } | null;
              const status = p.validation_status as string ?? "pending";
              return (
                <tr key={p.id} className="hover:bg-gray-50">
                  <td className="px-4 py-3">
                    <div className="font-medium text-gray-900">{bank?.name_ar ?? "—"}</div>
                    <div className="text-gray-400 text-xs font-mono">{bank?.short_code}</div>
                  </td>
                  <td className="px-4 py-3 font-mono text-xs text-gray-600 max-w-xs truncate">{p.sender_pattern}</td>
                  <td className="px-4 py-3">
                    <span className={`px-2 py-0.5 rounded text-xs font-medium ${p.transaction_type === "debit" ? "bg-red-50 text-red-600" : p.transaction_type === "credit" ? "bg-green-50 text-green-600" : "bg-gray-100 text-gray-500"}`}>
                      {p.transaction_type}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-gray-500 text-xs">{p.language}</td>
                  <td className="px-4 py-3 text-gray-500">{p.priority}</td>
                  <td className="px-4 py-3">
                    <span className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium ${statusLabel[status] ?? "bg-gray-100 text-gray-500"}`}>
                      {statusIcon[status]} {status}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <Link href={`/parsers/${p.id}`} className="inline-flex items-center gap-1 text-gray-400 hover:text-brand-500 transition-colors">
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
