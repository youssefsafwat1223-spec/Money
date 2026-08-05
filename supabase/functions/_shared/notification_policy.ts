// Server-side enforcement of the user's notification preferences (MALI-019).
//
// The app syncs `NotificationPreferences.toJson()` into
// `user_settings.notifications_json` (planning settings sync). Before this
// helper existed, every service-role push (budget/goal/streak/bill) treated
// all APNs devices as eligible — a user who disabled a type, or was inside
// quiet hours, still received sensitive lock-screen content.
//
// Quiet hours caveat: the stored hours are DEVICE-LOCAL wall clock and the
// server does not know the device timezone. We approximate with a coarse
// country→UTC-offset map covering the app's target markets; for unknown
// countries only the per-type toggles are enforced (never quiet hours), so a
// wrong offset can never suppress a wanted alert entirely — it only shifts
// the suppression window. Documented follow-up: sync the IANA timezone.

export type NotificationType =
  | 'budget_warning'
  | 'budget_over'
  | 'goal_milestone'
  | 'streak_reminder'
  | 'bill_reminder';

export interface NotificationPolicy {
  budgetWarning: boolean;
  budgetOver: boolean;
  goalMilestone: boolean;
  streakReminder: boolean;
  subscriptionReminder: boolean;
  quietHoursEnabled: boolean;
  quietHoursStartHour: number;
  quietHoursEndHour: number;
  /// UTC offset in hours derived from user_settings.country, null = unknown.
  utcOffsetHours: number | null;
}

const defaultPolicy: NotificationPolicy = {
  budgetWarning: true,
  budgetOver: true,
  goalMilestone: true,
  streakReminder: true,
  subscriptionReminder: true,
  quietHoursEnabled: false,
  quietHoursStartHour: 23,
  quietHoursEndHour: 8,
  utcOffsetHours: null,
};

// Fixed-offset approximation for the app's markets (no-DST or minor drift).
const countryUtcOffsets: Record<string, number> = {
  SA: 3,
  EG: 2,
  AE: 4,
  KW: 3,
  QA: 3,
  BH: 3,
  OM: 4,
  JO: 3,
  IQ: 3,
  YE: 3,
  LB: 2,
  PS: 2,
  LY: 2,
  SD: 2,
  DZ: 1,
  TN: 1,
  MA: 1,
};

// deno-lint-ignore no-explicit-any
export async function loadNotificationPolicy(
  supabase: any,
  userId: string,
): Promise<NotificationPolicy> {
  try {
    const { data } = await supabase
      .from('user_settings')
      .select('notifications_json, country')
      .eq('user_id', userId)
      .is('deleted_at', null)
      .limit(1)
      .maybeSingle();
    if (!data) return defaultPolicy;
    const country = (data.country as string | null)?.toUpperCase() ?? '';
    const utcOffsetHours = countryUtcOffsets[country] ?? null;
    const raw = data.notifications_json;
    if (!raw) return { ...defaultPolicy, utcOffsetHours };
    const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
    return {
      budgetWarning: parsed.budgetWarning !== false,
      budgetOver: parsed.budgetOver !== false,
      goalMilestone: parsed.goalMilestone !== false,
      streakReminder: parsed.streakReminder !== false,
      subscriptionReminder: parsed.subscriptionReminder !== false,
      quietHoursEnabled: parsed.quietHoursEnabled === true,
      quietHoursStartHour: typeof parsed.quietHoursStartHour === 'number'
        ? parsed.quietHoursStartHour
        : defaultPolicy.quietHoursStartHour,
      quietHoursEndHour: typeof parsed.quietHoursEndHour === 'number'
        ? parsed.quietHoursEndHour
        : defaultPolicy.quietHoursEndHour,
      utcOffsetHours,
    };
  } catch {
    // Never let a malformed preferences blob block or crash a worker —
    // fail open to defaults (all types enabled, no quiet hours).
    return defaultPolicy;
  }
}

/// True when [type] may be pushed to this user right now.
export function isPushAllowed(
  policy: NotificationPolicy,
  type: NotificationType,
  now: Date = new Date(),
): boolean {
  const typeEnabled = {
    budget_warning: policy.budgetWarning,
    budget_over: policy.budgetOver,
    goal_milestone: policy.goalMilestone,
    streak_reminder: policy.streakReminder,
    bill_reminder: policy.subscriptionReminder,
  }[type];
  if (!typeEnabled) return false;

  if (policy.quietHoursEnabled && policy.utcOffsetHours !== null) {
    const localHour = (now.getUTCHours() + policy.utcOffsetHours + 24) % 24;
    const start = policy.quietHoursStartHour;
    const end = policy.quietHoursEndHour;
    const inQuietHours = start <= end ? localHour >= start && localHour < end : localHour >= start || localHour < end; // wraps past midnight
    if (inQuietHours) return false;
  }
  return true;
}

/// MALI-061n coordination — the LOCAL app is the primary budget-alert authority
/// (it fires immediately when a transaction is processed). The server is a
/// FALLBACK that pushes only when NO device has been active recently, so the
/// local immediate alert could not have fired. Pure + tested.
export function anyDeviceRecentlyActive(
  lastSeenAtValues: Array<string | null | undefined>,
  nowMs: number,
  windowMs: number,
): boolean {
  return lastSeenAtValues.some((value) => {
    if (!value) return false;
    const t = Date.parse(value);
    return Number.isFinite(t) && nowMs - t < windowMs;
  });
}
