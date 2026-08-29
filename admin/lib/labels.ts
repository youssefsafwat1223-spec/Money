import type { Tone } from "@/components/ui/primitives";

/**
 * Presentation-only Arabic vocabulary.
 *
 * The database keeps its enum values exactly as they are — nothing here is
 * written back, parsed, or compared server-side. This module exists so a raw
 * value like `force_update` or `balance_inquiry` never reaches the operator's
 * screen as the primary label.
 *
 * Every lookup falls back to the raw value, so a new enum member added on the
 * backend shows up untranslated instead of disappearing.
 */
function pick(map: Record<string, string>, key: string | null | undefined): string {
  if (!key) return "—";
  return map[key] ?? key;
}

/* ─────────────────────────────────────────── parsers / catalog ── */

const VALIDATION: Record<string, string> = {
  passed: "اجتازت الفحص",
  pending: "بانتظار الفحص",
  failed: "فشل الفحص",
};
const VALIDATION_TONE: Record<string, Tone> = {
  passed: "success",
  pending: "warning",
  failed: "danger",
};
export const validationLabel = (v: string | null | undefined) => pick(VALIDATION, v);
export const validationTone = (v: string | null | undefined): Tone =>
  (v && VALIDATION_TONE[v]) || "neutral";

const TXN_TYPE: Record<string, string> = {
  debit: "خصم",
  credit: "إيداع",
  balance_inquiry: "استعلام رصيد",
};
const TXN_TONE: Record<string, Tone> = {
  debit: "danger",
  credit: "success",
  balance_inquiry: "neutral",
};
export const txnTypeLabel = (v: string | null | undefined) => pick(TXN_TYPE, v);
export const txnTypeTone = (v: string | null | undefined): Tone => (v && TXN_TONE[v]) || "neutral";
export const TXN_TYPE_OPTIONS = Object.entries(TXN_TYPE).map(([value, label]) => ({ value, label }));

const LANGUAGE: Record<string, string> = {
  ar: "عربي",
  en: "إنجليزي",
  ar_en: "عربي وإنجليزي",
};
export const languageLabel = (v: string | null | undefined) => pick(LANGUAGE, v);
export const LANGUAGE_OPTIONS = Object.entries(LANGUAGE).map(([value, label]) => ({ value, label }));

const CATEGORY_TYPE: Record<string, string> = {
  expense: "مصروفات",
  income: "دخل",
  transfer: "تحويلات",
  saving: "ادخار",
};
export const categoryTypeLabel = (v: string | null | undefined) => pick(CATEGORY_TYPE, v);

/* ───────────────────────────────────────────────── announcements ── */

const SEVERITY: Record<string, string> = {
  info: "معلومة",
  warning: "تنبيه",
  maintenance: "صيانة",
  force_update: "تحديث إجباري",
};
const SEVERITY_TONE: Record<string, Tone> = {
  info: "info",
  warning: "warning",
  maintenance: "brand",
  force_update: "danger",
};
export const severityLabel = (v: string | null | undefined) => pick(SEVERITY, v);
export const severityTone = (v: string | null | undefined): Tone => (v && SEVERITY_TONE[v]) || "neutral";
export const SEVERITY_OPTIONS = [
  { value: "info", label: "معلومة — لافتة عادية" },
  { value: "warning", label: "تنبيه — أمر يحتاج انتباه المستخدم" },
  { value: "maintenance", label: "صيانة — عمل مجدول على الخدمة" },
  { value: "force_update", label: "تحديث إجباري — يمنع استخدام التطبيق" },
];

/* ─────────────────────────────────────────────────────── campaigns ── */

const CAMPAIGN_TYPE: Record<string, string> = {
  notification: "إشعار",
  dashboard_banner: "لافتة في الشاشة الرئيسية",
  settings_card: "بطاقة داخل الإعدادات",
  modal: "نافذة منبثقة",
};
export const campaignTypeLabel = (v: string | null | undefined) => pick(CAMPAIGN_TYPE, v);
export const CAMPAIGN_TYPE_OPTIONS = Object.entries(CAMPAIGN_TYPE).map(([value, label]) => ({
  value,
  label,
}));

const SEGMENT: Record<string, string> = {
  all: "كل المستخدمين",
  new_user: "مستخدم جديد",
  no_shortcut: "لم يفعّل الاختصار بعد",
  has_first_transaction: "سجّل أول عملية",
  inactive_3_days: "لم يفتح التطبيق منذ 3 أيام",
  active_user: "مستخدم نشِط",
  budget_user: "يستخدم الميزانيات",
};
export const segmentLabel = (v: string | null | undefined) => pick(SEGMENT, v);
export const SEGMENT_OPTIONS = Object.entries(SEGMENT).map(([value, label]) => ({ value, label }));

/* ───────────────────────────────────────────────── offers / coupons ── */

const COUPON_STATUS: Record<string, string> = {
  live: "معروض الآن",
  scheduled: "مجدول",
  expired: "منتهي",
  disabled: "متوقف",
};
const COUPON_STATUS_TONE: Record<string, Tone> = {
  live: "success",
  scheduled: "info",
  expired: "neutral",
  disabled: "warning",
};
export const couponStatusLabel = (v: string | null | undefined) => pick(COUPON_STATUS, v);
export const couponStatusTone = (v: string | null | undefined): Tone =>
  (v && COUPON_STATUS_TONE[v]) || "neutral";

const REDEMPTION: Record<string, string> = {
  code: "كود خصم",
  link: "رابط مباشر",
};
export const redemptionLabel = (v: string | null | undefined) => pick(REDEMPTION, v);

/* ────────────────────────────────────────────── referrals / rewards ── */

const REFERRAL_STATUS: Record<string, string> = {
  attributed: "مُسجَّلة",
  qualified: "مُحتسَبة",
  rejected: "مرفوضة",
  reversed: "أُلغيت",
};
const REFERRAL_STATUS_TONE: Record<string, Tone> = {
  attributed: "info",
  qualified: "success",
  rejected: "danger",
  reversed: "danger",
};
export const referralStatusLabel = (v: string | null | undefined) => pick(REFERRAL_STATUS, v);
export const referralStatusTone = (v: string | null | undefined): Tone =>
  (v && REFERRAL_STATUS_TONE[v]) || "neutral";

const ATTRIBUTION: Record<string, string> = {
  code: "بإدخال الكود",
  link: "عبر رابط الدعوة",
  deferred_deeplink: "عبر رابط مؤجَّل",
  manual: "يدويًا من الإدارة",
};
export const attributionLabel = (v: string | null | undefined) => pick(ATTRIBUTION, v);

const ENTITLEMENT_STATUS: Record<string, string> = {
  active: "سارية",
  expired: "منتهية",
  revoked: "مسحوبة",
  inactive: "غير مفعّلة",
};
export const entitlementStatusLabel = (v: string | null | undefined) => pick(ENTITLEMENT_STATUS, v);

const ENTITLEMENT_TYPE: Record<string, string> = {
  report_export_ad_free: "تصدير التقارير بدون إعلان",
};
export const entitlementTypeLabel = (v: string | null | undefined) => pick(ENTITLEMENT_TYPE, v);

const CYCLE_STATE: Record<string, string> = {
  open: "دورة مفتوحة",
  completed: "دورة مكتملة",
  closed: "دورة مغلقة",
};
export const cycleStateLabel = (v: string | null | undefined) => pick(CYCLE_STATE, v);

const AUDIT_ACTION: Record<string, string> = {
  grant: "منح ميزة",
  extend: "تمديد ميزة",
  shorten: "تقصير مدة ميزة",
  revoke: "سحب ميزة",
  adjust_progress: "تعديل عدد الدعوات",
  rotate_code: "تدوير كود الدعوة",
  reject_referral: "رفض دعوة",
  reverse_referral: "إلغاء احتساب دعوة",
  publish_rule: "نشر قاعدة جديدة",
  deactivate_rule: "إيقاف القاعدة السارية",
};
export const auditActionLabel = (v: string | null | undefined) => pick(AUDIT_ACTION, v);

/* ──────────────────────────────────────────────────── feature flags ── */

const VALUE_TYPE: Record<string, string> = {
  bool: "تشغيل/إيقاف",
  boolean: "تشغيل/إيقاف",
  string: "نص",
  int: "رقم",
  number: "رقم",
  json: "إعداد متقدم",
};
export const valueTypeLabel = (v: string | null | undefined) => pick(VALUE_TYPE, v);
