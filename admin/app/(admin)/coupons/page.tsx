"use client";
// Coupons Phase C3 — Coupon management. Reuses the existing Admin visual system
// (page shell, cards, Input/Select helpers, brand/slate Tailwind tokens) and the
// established data flow: client component -> /api/* trusted routes. The browser
// never holds a service-role key and never talks to Supabase tables directly.
import { useCallback, useEffect, useMemo, useState } from "react";
import { fmt, fmtDate } from "@/lib/utils";
import {
  couponStatus,
  normalizeSlug,
  normalizeTagKey,
} from "@/lib/coupon-validation.mjs";

type TagRow = { id: string; key: string; label_ar: string; label_en: string | null; sort_order: number };
type CategoryRow = { key: string; label_ar: string; label_en: string | null; sort_order: number; is_active: boolean };
type Coupon = {
  id: string;
  slug: string;
  partner_name: string;
  title_ar: string;
  title_en: string | null;
  description_ar: string;
  description_en: string | null;
  terms_ar: string | null;
  redemption_type: "code" | "link";
  code: string | null;
  partner_url: string | null;
  display_category_key: string;
  spend_hint_category_keys: string[];
  country_codes: string[];
  accent_hex: string | null;
  image_path: string | null;
  featured: boolean;
  priority: number;
  valid_from: string;
  valid_until: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  coupon_tag_links: { tag_id: string }[];
};
type Totals = Record<string, Record<string, number>>;

const STATUSES = ["all", "live", "scheduled", "expired", "disabled"] as const;
const SORTS = ["priority", "newest", "updated", "validity", "title"] as const;
/** Financial category keys offered as contextual ranking hints (static list). */
const SPEND_HINTS = [
  "restaurants", "groceries", "subscriptions", "shopping", "transport",
  "health", "travel", "bills", "entertainment", "education",
];

const emptyForm = {
  id: "",
  slug: "",
  partner_name: "",
  title_ar: "",
  title_en: "",
  description_ar: "",
  description_en: "",
  terms_ar: "",
  redemption_type: "code" as "code" | "link",
  code: "",
  partner_url: "",
  display_category_key: "",
  spend_hint_category_keys: [] as string[],
  is_global: true,
  country_codes: "" as string,
  accent_hex: "#2563EB",
  featured: false,
  priority: "0",
  valid_from: "",
  valid_until: "",
  is_active: true,
  tag_ids: [] as string[],
};

/** Convert a `datetime-local` value (browser local) to an absolute UTC ISO. */
function localToIso(value: string): string {
  if (!value) return "";
  return new Date(value).toISOString();
}
/** Convert a stored UTC ISO back into a `datetime-local` value. */
function isoToLocal(value: string | null): string {
  if (!value) return "";
  const d = new Date(value);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export default function CouponsPage() {
  const [coupons, setCoupons] = useState<Coupon[]>([]);
  const [tags, setTags] = useState<TagRow[]>([]);
  const [categories, setCategories] = useState<CategoryRow[]>([]);
  const [totals, setTotals] = useState<Totals>({});
  const [form, setForm] = useState(emptyForm);
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState<(typeof STATUSES)[number]>("all");
  const [typeFilter, setTypeFilter] = useState("all");
  const [categoryFilter, setCategoryFilter] = useState("all");
  const [tagFilter, setTagFilter] = useState("all");
  const [featuredOnly, setFeaturedOnly] = useState(false);
  const [sort, setSort] = useState<(typeof SORTS)[number]>("priority");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [previewId, setPreviewId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setError(null);
    const [cRes, tRes, catRes, aRes] = await Promise.all([
      fetch(`/api/coupons?sort=${sort}`),
      fetch("/api/coupon-tags"),
      fetch("/api/coupon-categories"),
      fetch("/api/coupon-analytics?days=30"),
    ]);
    const [cJson, tJson, catJson, aJson] = await Promise.all([
      cRes.json(), tRes.json(), catRes.json(), aRes.json(),
    ]);
    if (!cRes.ok) return setError(cJson.message ?? "Failed to load offers");
    setCoupons((cJson.coupons ?? []) as Coupon[]);
    setTags((tJson.tags ?? []) as TagRow[]);
    setCategories((catJson.categories ?? []) as CategoryRow[]);
    setTotals((aJson.totals ?? {}) as Totals);
  }, [sort]);

  useEffect(() => { void load(); }, [load]);

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return coupons.filter((c) => {
      if (status !== "all" && couponStatus(c) !== status) return false;
      if (typeFilter !== "all" && c.redemption_type !== typeFilter) return false;
      if (categoryFilter !== "all" && c.display_category_key !== categoryFilter) return false;
      if (featuredOnly && !c.featured) return false;
      if (tagFilter !== "all" && !c.coupon_tag_links?.some((l) => l.tag_id === tagFilter)) return false;
      if (!q) return true;
      return (
        c.title_ar.toLowerCase().includes(q) ||
        (c.title_en ?? "").toLowerCase().includes(q) ||
        c.partner_name.toLowerCase().includes(q) ||
        c.slug.toLowerCase().includes(q)
      );
    });
  }, [coupons, search, status, typeFilter, categoryFilter, tagFilter, featuredOnly]);

  function readError(json: { message?: string; fields?: { field: string; message: string }[] }) {
    if (json.fields?.length) {
      return json.fields.map((f) => `${f.field}: ${f.message}`).join(" · ");
    }
    return json.message ?? "Request failed";
  }

  function payloadFrom(f: typeof form) {
    return {
      ...(f.id ? { id: f.id } : {}),
      slug: f.slug,
      partner_name: f.partner_name,
      title_ar: f.title_ar,
      title_en: f.title_en || null,
      description_ar: f.description_ar,
      description_en: f.description_en || null,
      terms_ar: f.terms_ar || null,
      redemption_type: f.redemption_type,
      code: f.redemption_type === "code" ? f.code : "",
      partner_url: f.partner_url,
      display_category_key: f.display_category_key,
      spend_hint_category_keys: f.spend_hint_category_keys,
      is_global: f.is_global,
      country_codes: f.is_global
        ? []
        : f.country_codes.split(",").map((c) => c.trim().toUpperCase()).filter(Boolean),
      accent_hex: f.accent_hex || null,
      featured: f.featured,
      priority: Number(f.priority || 0),
      valid_from: localToIso(f.valid_from) || new Date().toISOString(),
      valid_until: f.valid_until ? localToIso(f.valid_until) : null,
      is_active: f.is_active,
      tag_ids: f.tag_ids,
    };
  }

  async function save() {
    setBusy(true);
    setError(null);
    setNotice(null);
    const editing = Boolean(form.id);
    const res = await fetch("/api/coupons", {
      method: editing ? "PATCH" : "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payloadFrom(form)),
    });
    const json = await res.json();
    setBusy(false);
    if (!res.ok) return setError(readError(json));
    setNotice(editing ? "Offer updated." : "Offer created.");
    setForm(emptyForm);
    await load();
  }

  function edit(c: Coupon) {
    setForm({
      id: c.id,
      slug: c.slug,
      partner_name: c.partner_name,
      title_ar: c.title_ar,
      title_en: c.title_en ?? "",
      description_ar: c.description_ar,
      description_en: c.description_en ?? "",
      terms_ar: c.terms_ar ?? "",
      redemption_type: c.redemption_type,
      code: c.code ?? "",
      partner_url: c.partner_url ?? "",
      display_category_key: c.display_category_key,
      spend_hint_category_keys: c.spend_hint_category_keys ?? [],
      is_global: (c.country_codes ?? []).length === 0,
      country_codes: (c.country_codes ?? []).join(", "),
      accent_hex: c.accent_hex ?? "#2563EB",
      featured: c.featured,
      priority: String(c.priority),
      valid_from: isoToLocal(c.valid_from),
      valid_until: isoToLocal(c.valid_until),
      is_active: c.is_active,
      tag_ids: (c.coupon_tag_links ?? []).map((l) => l.tag_id),
    });
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  async function setActive(c: Coupon, active: boolean) {
    setError(null);
    const res = await fetch("/api/coupons", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...payloadFrom({
          ...emptyForm,
          id: c.id,
          slug: c.slug,
          partner_name: c.partner_name,
          title_ar: c.title_ar,
          title_en: c.title_en ?? "",
          description_ar: c.description_ar,
          description_en: c.description_en ?? "",
          terms_ar: c.terms_ar ?? "",
          redemption_type: c.redemption_type,
          code: c.code ?? "",
          partner_url: c.partner_url ?? "",
          display_category_key: c.display_category_key,
          spend_hint_category_keys: c.spend_hint_category_keys ?? [],
          is_global: (c.country_codes ?? []).length === 0,
          country_codes: (c.country_codes ?? []).join(", "),
          accent_hex: c.accent_hex ?? "#2563EB",
          featured: c.featured,
          priority: String(c.priority),
          valid_from: isoToLocal(c.valid_from),
          valid_until: isoToLocal(c.valid_until),
          tag_ids: (c.coupon_tag_links ?? []).map((l) => l.tag_id),
        }),
        is_active: active,
      }),
    });
    const json = await res.json();
    if (!res.ok) return setError(readError(json));
    setNotice(active ? "Offer enabled." : "Offer disabled (content preserved).");
    await load();
  }

  async function permanentlyDelete(c: Coupon) {
    const typed = window.prompt(
      `PERMANENT delete removes the offer, its tag links, its analytics and its image.\n` +
        `Prefer "Disable" for routine retirement.\n\nType the slug to confirm:`,
    );
    if (typed !== c.slug) return;
    const res = await fetch(
      `/api/coupons?id=${encodeURIComponent(c.id)}&confirm=permanent`,
      { method: "DELETE" },
    );
    const json = await res.json();
    if (!res.ok) return setError(readError(json));
    setNotice("Offer permanently deleted.");
    await load();
  }

  async function uploadImage(c: Coupon, file: File) {
    setError(null);
    const body = new FormData();
    body.append("coupon_id", c.id);
    body.append("file", file);
    const res = await fetch("/api/coupons/image", { method: "POST", body });
    const json = await res.json();
    if (!res.ok) return setError(readError(json));
    setNotice("Image updated.");
    await load();
  }

  async function removeImage(c: Coupon) {
    const res = await fetch(`/api/coupons/image?coupon_id=${encodeURIComponent(c.id)}`, {
      method: "DELETE",
    });
    const json = await res.json();
    if (!res.ok) return setError(readError(json));
    setNotice("Image removed — the offer falls back to its accent colour.");
    await load();
  }

  const preview = coupons.find((c) => c.id === previewId) ?? null;

  return (
    <div className="p-8 space-y-8">
      <div>
        <p className="text-sm text-slate-500">Growth</p>
        <h1 className="text-2xl font-semibold text-slate-900">Offers &amp; Coupons</h1>
        <p className="text-sm text-slate-500">
          {coupons.length} offers · {coupons.filter((c) => couponStatus(c) === "live").length} live.
          Content can be prepared before the mobile feature flag is enabled.
        </p>
      </div>

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">{error}</div>
      )}
      {notice && (
        <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-700">{notice}</div>
      )}

      {/* ---------------------------------------------------------------- form */}
      <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
        <h2 className="mb-4 text-lg font-semibold text-slate-900">
          {form.id ? "Edit offer" : "Create offer"}
        </h2>

        <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Identity</h3>
        <div className="grid gap-4 md:grid-cols-2">
          <Input
            label="Slug"
            value={form.slug}
            onChange={(v) => setForm({ ...form, slug: v })}
            hint="lowercase, digits, - or _"
          />
          <Input
            label="Partner / merchant"
            value={form.partner_name}
            onChange={(v) =>
              setForm({
                ...form,
                partner_name: v,
                slug: form.id || form.slug ? form.slug : normalizeSlug(v),
              })
            }
          />
        </div>

        <h3 className="mt-5 mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Content</h3>
        <div className="grid gap-4 md:grid-cols-2">
          <Input label="Arabic title *" value={form.title_ar} onChange={(v) => setForm({ ...form, title_ar: v })} />
          <Input label="English title" value={form.title_en} onChange={(v) => setForm({ ...form, title_en: v })} />
          <Input label="Arabic description *" value={form.description_ar} onChange={(v) => setForm({ ...form, description_ar: v })} />
          <Input label="English description" value={form.description_en} onChange={(v) => setForm({ ...form, description_en: v })} />
          <Input label="Arabic terms" value={form.terms_ar} onChange={(v) => setForm({ ...form, terms_ar: v })} />
        </div>

        <h3 className="mt-5 mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Redemption</h3>
        <div className="grid gap-4 md:grid-cols-2">
          <Select
            label="Type"
            value={form.redemption_type}
            options={["code", "link"]}
            onChange={(v) => setForm({ ...form, redemption_type: v as "code" | "link", code: v === "link" ? "" : form.code })}
          />
          {form.redemption_type === "code" ? (
            <Input label="Coupon code *" value={form.code} onChange={(v) => setForm({ ...form, code: v })} />
          ) : (
            <div className="text-sm text-slate-500 self-end pb-2">
              A link offer carries no code — the destination is the whole offer.
            </div>
          )}
          <Input
            label={form.redemption_type === "link" ? "Destination URL * (https)" : "Partner URL (optional, https)"}
            value={form.partner_url}
            onChange={(v) => setForm({ ...form, partner_url: v })}
          />
        </div>

        <h3 className="mt-5 mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Classification</h3>
        <div className="grid gap-4 md:grid-cols-2">
          <Select
            label="Display category *"
            value={form.display_category_key}
            options={categories.filter((c) => c.is_active).map((c) => c.key)}
            onChange={(v) => setForm({ ...form, display_category_key: v })}
          />
          <div>
            <label className="mb-1 block text-sm font-medium text-slate-700">Tags</label>
            <div className="flex flex-wrap gap-2 rounded-lg border border-slate-200 p-2">
              {tags.map((t) => {
                const on = form.tag_ids.includes(t.id);
                return (
                  <button
                    key={t.id}
                    type="button"
                    onClick={() =>
                      setForm({
                        ...form,
                        tag_ids: on ? form.tag_ids.filter((x) => x !== t.id) : [...form.tag_ids, t.id],
                      })
                    }
                    className={
                      on
                        ? "rounded-full bg-brand-600 px-3 py-1 text-xs font-medium text-white"
                        : "rounded-full bg-slate-100 px-3 py-1 text-xs text-slate-600"
                    }
                  >
                    #{t.label_ar}
                  </button>
                );
              })}
              {tags.length === 0 && <span className="text-xs text-slate-400">No tags yet — create one below.</span>}
            </div>
          </div>
        </div>

        <div className="mt-4">
          <label className="mb-1 block text-sm font-medium text-slate-700">
            Contextual ranking hints
            <span className="ml-2 font-normal text-xs text-slate-500">
              Optional. Used only for on-device ordering — this does NOT categorize anyone&apos;s transactions.
            </span>
          </label>
          <div className="flex flex-wrap gap-2">
            {SPEND_HINTS.map((h) => {
              const on = form.spend_hint_category_keys.includes(h);
              return (
                <button
                  key={h}
                  type="button"
                  onClick={() =>
                    setForm({
                      ...form,
                      spend_hint_category_keys: on
                        ? form.spend_hint_category_keys.filter((x) => x !== h)
                        : [...form.spend_hint_category_keys, h],
                    })
                  }
                  className={
                    on
                      ? "rounded-full bg-slate-800 px-3 py-1 text-xs text-white"
                      : "rounded-full bg-slate-100 px-3 py-1 text-xs text-slate-600"
                  }
                >
                  {h}
                </button>
              );
            })}
          </div>
          {form.spend_hint_category_keys.filter((h) => !SPEND_HINTS.includes(h)).length > 0 && (
            <p className="mt-2 text-xs text-slate-500">
              Also kept from earlier edits:{" "}
              {form.spend_hint_category_keys.filter((h) => !SPEND_HINTS.includes(h)).join(", ")}
            </p>
          )}
        </div>

        <h3 className="mt-5 mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Availability</h3>
        <div className="grid gap-4 md:grid-cols-2">
          <label className="flex items-center gap-2 text-sm text-slate-700">
            <input
              type="checkbox"
              checked={form.is_global}
              onChange={(e) => setForm({ ...form, is_global: e.target.checked })}
            />
            Available globally
          </label>
          <Input
            label="Countries (ISO alpha-2, comma separated)"
            value={form.is_global ? "" : form.country_codes}
            onChange={(v) => setForm({ ...form, country_codes: v })}
            hint={form.is_global ? "Disabled while the offer is global" : "e.g. SA, AE, EG"}
          />
          <Input label="Valid from" type="datetime-local" value={form.valid_from} onChange={(v) => setForm({ ...form, valid_from: v })} />
          <Input label="Valid until (empty = open-ended)" type="datetime-local" value={form.valid_until} onChange={(v) => setForm({ ...form, valid_until: v })} />
        </div>
        <p className="mt-1 text-xs text-slate-500">
          Times are entered in your local timezone and stored as UTC. Effective window:{" "}
          {form.valid_from ? new Date(localToIso(form.valid_from)).toUTCString() : "now"} →{" "}
          {form.valid_until ? new Date(localToIso(form.valid_until)).toUTCString() : "open-ended"}.
        </p>

        <h3 className="mt-5 mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Presentation</h3>
        <div className="grid gap-4 md:grid-cols-3">
          <Input label="Accent hex" value={form.accent_hex} onChange={(v) => setForm({ ...form, accent_hex: v })} />
          <Input label="Priority (-1000…1000)" value={form.priority} onChange={(v) => setForm({ ...form, priority: v })} />
          <div className="flex items-end gap-5 text-sm text-slate-700">
            <label className="flex items-center gap-2">
              <input type="checkbox" checked={form.featured} onChange={(e) => setForm({ ...form, featured: e.target.checked })} />
              Featured
            </label>
            <label className="flex items-center gap-2">
              <input type="checkbox" checked={form.is_active} onChange={(e) => setForm({ ...form, is_active: e.target.checked })} />
              Active
            </label>
          </div>
        </div>
        <p className="mt-2 text-xs text-slate-500">
          Artwork is uploaded from the offer row after saving (16:9, ~1200×675 recommended, max 512 KB, WebP/PNG/JPEG).
        </p>

        <div className="mt-5 flex gap-3">
          <button
            className="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white disabled:opacity-50"
            disabled={busy}
            onClick={save}
          >
            {form.id ? "Save changes" : "Create offer"}
          </button>
          {form.id && (
            <button className="rounded-lg border border-slate-300 px-4 py-2 text-sm" onClick={() => setForm(emptyForm)}>
              Cancel edit
            </button>
          )}
        </div>
      </section>

      {/* ------------------------------------------------------------- filters */}
      <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
        <div className="grid gap-3 md:grid-cols-6">
          <Input label="Search (title, partner, slug)" value={search} onChange={setSearch} />
          <Select label="Status" value={status} options={[...STATUSES]} onChange={(v) => setStatus(v as typeof status)} />
          <Select label="Type" value={typeFilter} options={["all", "code", "link"]} onChange={setTypeFilter} />
          <Select label="Category" value={categoryFilter} options={["all", ...categories.map((c) => c.key)]} onChange={setCategoryFilter} />
          <Select label="Tag" value={tagFilter} options={["all", ...tags.map((t) => t.id)]} onChange={setTagFilter} />
          <Select label="Sort" value={sort} options={[...SORTS]} onChange={(v) => setSort(v as typeof sort)} />
        </div>
        <label className="mt-3 flex items-center gap-2 text-sm text-slate-700">
          <input type="checkbox" checked={featuredOnly} onChange={(e) => setFeaturedOnly(e.target.checked)} />
          Featured only
        </label>
      </section>

      {/* ---------------------------------------------------------------- list */}
      <section className="overflow-x-auto rounded-xl border border-slate-200 bg-white shadow-sm">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-4 py-3">Offer</th>
              <th className="px-4 py-3">Partner</th>
              <th className="px-4 py-3">Category</th>
              <th className="px-4 py-3">Type</th>
              <th className="px-4 py-3">Status</th>
              <th className="px-4 py-3">Window</th>
              <th className="px-4 py-3">Priority</th>
              <th className="px-4 py-3">Impr.</th>
              <th className="px-4 py-3">Detail</th>
              <th className="px-4 py-3">Copies</th>
              <th className="px-4 py-3">Clicks</th>
              <th className="px-4 py-3">Actions</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {visible.map((c) => {
              const t = totals[c.id] ?? {};
              return (
                <tr key={c.id}>
                  <td className="px-4 py-3">
                    <div className="flex items-center gap-3">
                      <div
                        className="h-10 w-16 shrink-0 rounded-md bg-slate-100"
                        style={c.accent_hex ? { backgroundColor: c.accent_hex } : undefined}
                        title={c.image_path ?? "accent fallback"}
                      />
                      <div>
                        <div className="font-medium text-slate-900">{c.title_ar}</div>
                        <div className="text-xs text-slate-500">{c.slug}{c.featured ? " · featured" : ""}</div>
                      </div>
                    </div>
                  </td>
                  <td className="px-4 py-3 text-slate-700">{c.partner_name}</td>
                  <td className="px-4 py-3 text-slate-700">{c.display_category_key}</td>
                  <td className="px-4 py-3 text-slate-700">{c.redemption_type}</td>
                  <td className="px-4 py-3"><StatusBadge status={couponStatus(c)} /></td>
                  <td className="px-4 py-3 text-xs text-slate-500">
                    {fmtDate(c.valid_from)} → {c.valid_until ? fmtDate(c.valid_until) : "open"}
                  </td>
                  <td className="px-4 py-3 text-slate-700">{c.priority}</td>
                  <td className="px-4 py-3 text-slate-700">{fmt(t.impression ?? 0)}</td>
                  <td className="px-4 py-3 text-slate-700">{fmt(t.detail_view ?? 0)}</td>
                  <td className="px-4 py-3 text-slate-700">{fmt(t.code_copy ?? 0)}</td>
                  <td className="px-4 py-3 text-slate-700">{fmt(t.cta_click ?? 0)}</td>
                  <td className="px-4 py-3">
                    <div className="flex flex-wrap gap-2 text-xs">
                      <button className="rounded border border-slate-300 px-2 py-1" onClick={() => edit(c)}>Edit</button>
                      <button className="rounded border border-slate-300 px-2 py-1" onClick={() => setPreviewId(c.id)}>Preview</button>
                      <button className="rounded border border-slate-300 px-2 py-1" onClick={() => setActive(c, !c.is_active)}>
                        {c.is_active ? "Disable" : "Enable"}
                      </button>
                      <label className="cursor-pointer rounded border border-slate-300 px-2 py-1">
                        Image
                        <input
                          type="file"
                          accept="image/webp,image/png,image/jpeg"
                          className="hidden"
                          onChange={(e) => e.target.files?.[0] && uploadImage(c, e.target.files[0])}
                        />
                      </label>
                      {c.image_path && (
                        <button className="rounded border border-slate-300 px-2 py-1" onClick={() => removeImage(c)}>
                          Clear image
                        </button>
                      )}
                      <button className="rounded border border-red-200 px-2 py-1 text-red-600" onClick={() => permanentlyDelete(c)}>
                        Delete…
                      </button>
                    </div>
                  </td>
                </tr>
              );
            })}
            {visible.length === 0 && (
              <tr><td className="px-4 py-6 text-center text-slate-500" colSpan={12}>No offers match these filters.</td></tr>
            )}
          </tbody>
        </table>
      </section>

      <p className="text-xs text-slate-500">
        Impressions, detail views, code copies and clicks are <strong>directional product analytics</strong>,
        not billing-grade redemption or conversion accounting.
      </p>

      {preview && <PreviewCard coupon={preview} categories={categories} tags={tags} onClose={() => setPreviewId(null)} />}

      <CategoryManager categories={categories} onChanged={load} onError={setError} onNotice={setNotice} />
      <TagManager tags={tags} onChanged={load} onError={setError} onNotice={setNotice} />
    </div>
  );
}

/* ------------------------------------------------------------------ managers */

function CategoryManager({
  categories, onChanged, onError, onNotice,
}: {
  categories: CategoryRow[];
  onChanged: () => Promise<void>;
  onError: (m: string) => void;
  onNotice: (m: string) => void;
}) {
  const [key, setKey] = useState("");
  const [labelAr, setLabelAr] = useState("");
  const [labelEn, setLabelEn] = useState("");

  async function send(method: "POST" | "PATCH", body: Record<string, unknown>) {
    const res = await fetch("/api/coupon-categories", {
      method,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const json = await res.json();
    if (!res.ok) return onError(json.message ?? "Category request failed");
    onNotice("Categories updated.");
    await onChanged();
  }

  return (
    <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
      <h2 className="mb-1 text-lg font-semibold text-slate-900">Display categories</h2>
      <p className="mb-4 text-xs text-slate-500">
        Offer-owned taxonomy — independent of the app&apos;s transaction categories.
      </p>
      <div className="grid gap-3 md:grid-cols-4">
        <Input label="Key" value={key} onChange={setKey} hint="a-z, 0-9, _" />
        <Input label="Arabic label" value={labelAr} onChange={setLabelAr} />
        <Input label="English label" value={labelEn} onChange={setLabelEn} />
        <button
          className="self-end rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white"
          onClick={() => send("POST", { key, label_ar: labelAr, label_en: labelEn })}
        >
          Add category
        </button>
      </div>
      <ul className="mt-4 divide-y divide-slate-100 text-sm">
        {categories.map((c) => (
          <li key={c.key} className="flex flex-wrap items-center gap-3 py-2">
            <span className="w-40 font-medium text-slate-800">{c.key}</span>
            <span className="text-slate-600">{c.label_ar}</span>
            <span className="text-slate-400">{c.label_en ?? "—"}</span>
            <span className="text-xs text-slate-500">order {c.sort_order}</span>
            <div className="ml-auto flex gap-2 text-xs">
              <button
                className="rounded border border-slate-300 px-2 py-1"
                onClick={() => send("PATCH", { ...c, sort_order: c.sort_order - 1 })}
              >
                ↑
              </button>
              <button
                className="rounded border border-slate-300 px-2 py-1"
                onClick={() => send("PATCH", { ...c, sort_order: c.sort_order + 1 })}
              >
                ↓
              </button>
              <button
                className="rounded border border-slate-300 px-2 py-1"
                onClick={() => send("PATCH", { ...c, is_active: !c.is_active })}
              >
                {c.is_active ? "Deactivate" : "Activate"}
              </button>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}

function TagManager({
  tags, onChanged, onError, onNotice,
}: {
  tags: TagRow[];
  onChanged: () => Promise<void>;
  onError: (m: string) => void;
  onNotice: (m: string) => void;
}) {
  const [labelAr, setLabelAr] = useState("");
  const [labelEn, setLabelEn] = useState("");
  const [query, setQuery] = useState("");

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? tags.filter((t) => t.key.includes(q) || t.label_ar.includes(q)) : tags;
  }, [tags, query]);

  async function create() {
    const res = await fetch("/api/coupon-tags", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: labelAr, label_ar: labelAr, label_en: labelEn }),
    });
    const json = await res.json();
    if (!res.ok) return onError(json.message ?? "Tag request failed");
    setLabelAr("");
    setLabelEn("");
    onNotice("Tag created.");
    await onChanged();
  }

  return (
    <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
      <h2 className="mb-1 text-lg font-semibold text-slate-900">Tags</h2>
      <p className="mb-4 text-xs text-slate-500">
        Normalized keys with Arabic display labels. Attach tags from the offer form above.
      </p>
      <div className="grid gap-3 md:grid-cols-4">
        <Input label="Arabic label" value={labelAr} onChange={setLabelAr} hint={labelAr ? `key: ${normalizeTagKey(labelAr)}` : "key preview"} />
        <Input label="English label" value={labelEn} onChange={setLabelEn} />
        <button className="self-end rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white" onClick={create}>
          Create tag
        </button>
        <Input label="Search tags" value={query} onChange={setQuery} />
      </div>
      <div className="mt-4 flex flex-wrap gap-2">
        {shown.map((t) => (
          <span key={t.id} className="rounded-full bg-slate-100 px-3 py-1 text-xs text-slate-700">
            #{t.label_ar} <span className="text-slate-400">({t.key})</span>
          </span>
        ))}
        {shown.length === 0 && <span className="text-xs text-slate-400">No tags.</span>}
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------- preview */

function PreviewCard({
  coupon, categories, tags, onClose,
}: {
  coupon: Coupon;
  categories: CategoryRow[];
  tags: TagRow[];
  onClose: () => void;
}) {
  const category = categories.find((c) => c.key === coupon.display_category_key);
  const linked = (coupon.coupon_tag_links ?? [])
    .map((l) => tags.find((t) => t.id === l.tag_id))
    .filter(Boolean) as TagRow[];
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-lg font-semibold text-slate-900">Preview</h2>
        <button className="text-sm text-slate-500" onClick={onClose}>Close</button>
      </div>
      <div className="max-w-sm rounded-2xl border border-slate-200 p-4" dir="rtl">
        <div className="h-28 rounded-xl" style={{ backgroundColor: coupon.accent_hex ?? "#e2e8f0" }} />
        <p className="mt-3 text-xs text-slate-500">{coupon.partner_name}</p>
        <h3 className="text-base font-semibold text-slate-900">{coupon.title_ar}</h3>
        <p className="mt-1 text-sm text-slate-600">{coupon.description_ar}</p>
        <div className="mt-2 flex flex-wrap gap-1 text-xs">
          {category && <span className="rounded-full bg-slate-100 px-2 py-0.5">{category.label_ar}</span>}
          {linked.map((t) => (
            <span key={t.id} className="rounded-full bg-slate-100 px-2 py-0.5">#{t.label_ar}</span>
          ))}
        </div>
        <div className="mt-3 rounded-lg bg-slate-900 px-3 py-2 text-center text-sm font-semibold text-white">
          {coupon.redemption_type === "code" ? `انسخ الكود: ${coupon.code}` : "احصل على العرض"}
        </div>
        <p className="mt-2 text-[11px] text-slate-500">
          {fmtDate(coupon.valid_from)} → {coupon.valid_until ? fmtDate(coupon.valid_until) : "مفتوح"}
          {coupon.country_codes.length === 0 ? " · كل الدول" : ` · ${coupon.country_codes.join(", ")}`}
        </p>
      </div>
    </section>
  );
}

/* -------------------------------------------------------------------- inputs */

function StatusBadge({ status }: { status: string }) {
  const styles: Record<string, string> = {
    live: "bg-emerald-100 text-emerald-700",
    scheduled: "bg-blue-100 text-blue-700",
    expired: "bg-slate-200 text-slate-600",
    disabled: "bg-amber-100 text-amber-700",
  };
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${styles[status] ?? "bg-slate-100"}`}>
      {status}
    </span>
  );
}

function Input({
  label, value, onChange, hint, type = "text",
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  hint?: string;
  type?: string;
}) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block font-medium text-slate-700">{label}</span>
      <input
        type={type}
        className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
      {hint && <span className="mt-1 block text-xs text-slate-500">{hint}</span>}
    </label>
  );
}

function Select({
  label, value, options, onChange,
}: {
  label: string;
  value: string;
  options: string[];
  onChange: (v: string) => void;
}) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block font-medium text-slate-700">{label}</span>
      <select
        className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      >
        <option value="">—</option>
        {options.map((o) => (
          <option key={o} value={o}>{o}</option>
        ))}
      </select>
    </label>
  );
}
