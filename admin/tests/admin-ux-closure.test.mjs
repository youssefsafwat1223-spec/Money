import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

/**
 * Phase J — the Admin-surface QA findings (UX-017…UX-021).
 *
 * These are operator-trust defects rather than styling: in each case the panel
 * showed something that led a business operator to a wrong conclusion. Asserted
 * against source, because each finding is a property of what the page renders.
 */
const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

test("UX-017: the parsers list shows the pattern that actually extracts fields", () => {
  const page = read("app/(admin)/parsers/page.tsx");
  const table = read("app/(admin)/parsers/parsers-table.tsx");

  // `sender_pattern` only decides which messages are considered; the amount,
  // merchant and date come out of `message_pattern`. The list showed the
  // second and hid the first, so two rules for the same bank were
  // indistinguishable.
  assert.match(page, /message_pattern/, "must be selected from the DB");
  assert.match(table, /message_pattern: string \| null;/);
  assert.match(table, /"نمط الرسالة"/, "must have its own column");
  assert.match(table, /p\.message_pattern \?\? ""/, "full value on hover");
});

test("UX-017: the pattern is searchable, not just displayed", () => {
  const table = read("app/(admin)/parsers/parsers-table.tsx");
  assert.match(table, /p\.message_pattern \?\? ""\)\.toLowerCase\(\)\.includes\(q\)/);
});

test("UX-018: the all_expenses sentinel is marked, not passed off as a category", () => {
  const labels = read("lib/labels.ts");
  const table = read("app/(admin)/categories/categories-table.tsx");

  assert.match(labels, /SENTINEL_CATEGORY_KEYS/);
  assert.match(labels, /"all_expenses"/);
  assert.match(table, /isSentinelCategory\(c\.key\)/);
  assert.match(table, /ليست فئة إنفاق/);
});

test("UX-018: it is LABELLED rather than hidden", () => {
  // The row is real — it is what an all-expenses budget stores. An operator who
  // finds it in the data should still find it in the panel.
  const table = read("app/(admin)/categories/categories-table.tsx");
  assert.doesNotMatch(
    table,
    /filter\([^)]*isSentinelCategory/,
    "hiding it would trade one wrong impression for another",
  );
});

test("UX-019: the key-dependency note names the tables that actually depend on it", () => {
  const page = read("app/(admin)/categories/page.tsx");

  // The old note blamed «قواعد قراءة الرسائل» (sms_parsers). That table has no
  // category column at all, so the stated reason not to edit a key was simply
  // not the real one.
  assert.doesNotMatch(
    page,
    /«المفتاح الثابت» لكل فئة تعتمد عليه قواعد قراءة/,
    "the false attribution must be gone",
  );
  assert.match(page, /عمليات المستخدمين/);
  assert.match(page, /ميزانياتهم/);
  assert.match(page, /كلمات التجّار/);
});

test("UX-019: it explains WHY renaming is unsafe — no FK, so it fails silently", () => {
  const page = read("app/(admin)/categories/page.tsx");
  assert.match(page, /بدون رابط يمنع كسره/);
  assert.match(page, /بصمت/);
});

test("UX-020: an empty collection shows no «0 من 0» counter", () => {
  const bar = read("components/ui/filter-bar.tsx");
  assert.match(bar, /export function resultCountLabel/);
  assert.match(
    bar,
    /if \(total === 0\) return undefined;/,
    "0 من 0 reads as breakage, not as emptiness",
  );
});

test("UX-020: every table derives the counter from counts, not its own string", () => {
  // The rule belongs to the component. Six call sites each building their own
  // label is six chances to forget it, and every future table would be a
  // seventh.
  const files = [
    "app/(admin)/parsers/parsers-table.tsx",
    "app/(admin)/flags/page.tsx",
    "app/(admin)/coupons/page.tsx",
    "app/(admin)/campaigns/page.tsx",
    "app/(admin)/categories/categories-table.tsx",
    "app/(admin)/banks/banks-table.tsx",
  ];
  for (const f of files) {
    const src = read(f);
    assert.match(src, /visibleCount=\{/, `${f} must pass counts`);
    assert.match(src, /totalCount=\{/, `${f} must pass counts`);
    assert.doesNotMatch(
      src,
      /resultLabel=\{`\$\{fmt\(/,
      `${f} must not rebuild the label itself`,
    );
  }
});

test("UX-021: flags read as what they DO, in the operator's language", () => {
  const labels = read("lib/labels.ts");
  const page = read("app/(admin)/flags/page.tsx");

  assert.match(labels, /export function flagDescription/);
  assert.match(labels, /enable_goals: "إظهار قسم الأهداف/);
  assert.match(page, /flagDescription\(flag\.key, flag\.description\)/);
});

test("UX-021: an unknown key keeps its stored description rather than losing it", () => {
  // A flag added after this map must not silently render as "no description".
  const labels = read("lib/labels.ts");
  assert.match(labels, /FLAG_DESCRIPTION\[key\] \?\? stored \?\? undefined/);
});

test("UX-021: a switch wired to nothing says so", () => {
  // F-018 found three active flags read by no code. An operator has no way to
  // discover that from the panel — MALI-034 retired the Supabase-primary
  // routing and left the rows behind.
  const labels = read("lib/labels.ts");
  const page = read("app/(admin)/flags/page.tsx");

  assert.match(labels, /RETIRED_FLAG_KEYS/);
  assert.match(labels, /"accounts_supabase_primary"/);
  assert.match(page, /isRetiredFlag\(flag\.key\)/);
  assert.match(page, /لن يؤثر على أي سلوك/);
});
