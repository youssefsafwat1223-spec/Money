# PROMOTION DIFF REPORT — Qirsh Admin UI → Main

Source (approved, read-only): `demo-docker/admin`
Target: `/Users/youssef/Documents/Money/admin`
Branch `feat/phase1-data-integrity` · HEAD `12f36726` (unchanged) · **NOT COMMITTED, NOT PUSHED**

> **Target-path correction.** The brief named `/Users/youssef/Documents/Money/app/admin`.
> That path does not exist — `app/` is the Flutter project (`app/pubspec.yaml`,
> `name: money_companion`). The real Main Admin is `/Users/youssef/Documents/Money/admin`
> (65 git-tracked files, Next.js `mali-admin`), mirroring the demo's own `demo-docker/admin`.
> Promotion was performed there.

---

## Pre-promotion state (recorded before any write)

- 117 `git status` entries repo-wide, of which only 4 were Admin-scoped:
  - `M  admin/app/(admin)/referrals/page.tsx` — **uncommitted H-13 remediation**
  - `D  admin/tsconfig.tsbuildinfo` — staged deletion (file is `.gitignore`d, line 48)
  - `?? admin/lib/operation-intent.mjs` — **untracked H-13 state machine**
  - `?? admin/tests/operation-intent.test.mjs` — **untracked H-13 test**
- Baseline tests: **66 tests, 65 pass, 1 skipped, 0 fail** (`Z2` skips without a build output).
- SHA-256 of every file to be modified: `scratchpad/promo/01_pre_hashes.txt`.

**HEAD does not contain the current Admin state** — the H-13 work is worktree-only. It was
treated as authoritative and preserved.

---

## A. Three-way reconciliation — did Main gain logic after the demo copy?

**No.** Proven by byte comparison, not inference:

| Group | Result |
|---|---|
| All 21 files under `app/api/**` | **identical**, 0 differing |
| `lib/operation-intent.mjs` | **identical** |
| `lib/auth-guard.ts`, `lib/referral-rpc.ts` | **identical** |
| `lib/coupon-validation.mjs`, `lib/coupon-errors.mjs` | **identical** |
| `lib/referral-validation.mjs`, `lib/referral-errors.mjs` | **identical** |
| `tests/admin-authorization.test.mjs`, `tests/operation-intent.test.mjs` | **identical** |
| `package.json`, `next.config.mjs`, `tsconfig.json` | **identical** |

The demo snapshot already carried the H-13 remediation, so there was no newer Main logic to
protect. Route inventories are identical in both trees — **no Main-only routes** exist, so the
new grouped navigation drops nothing.

---

## B. Files copied unchanged (18 new)

`lib/nav.ts` · `lib/labels.ts` · `components/ui/{primitives,form,table,confirm-dialog,copy-id,filter-bar,pagination}.tsx` ·
`app/(admin)/banks/banks-table.tsx` · `app/(admin)/parsers/parsers-table.tsx` ·
`app/(admin)/categories/categories-table.tsx` ·
`public/brand/qirsh-coin.png` · `public/brand/qirsh-lockup-dark.png` ·
`public/fonts/IBMPlexSansArabic-{Regular,Medium,SemiBold,Bold}.ttf`

## C. Files replaced (22 — verified presentation-only)

`tailwind.config.ts` · `app/globals.css` · `app/layout.tsx` · `app/(admin)/layout.tsx` ·
`components/sidebar.tsx` · `lib/utils.ts` · the 12 `(admin)` pages · `login` · `not-authorized` ·
`tests/coupon-admin.test.mjs` · `tests/referral-admin.test.mjs`

## D. REVIEW files — partially promoted

| File | Decision | Evidence |
|---|---|---|
| `middleware.ts` | **matcher hunk only** | `git diff` against HEAD shows a single hunk at `export const config`. The guard body — `getUser()`, the `admin_users` lookup, all three redirects — is untouched. The demo's `import "./lib/demo-guard"` was **not** promoted. |
| `lib/supabase.ts` | **excluded entirely** | Sole difference vs Main is the demo-guard import. No UI change existed to promote. |
| `lib/supabase-server.ts` | **excluded entirely** | Same. |
| `app/(admin)/coupons/page.tsx` | promoted after logic diff | Logic-bearing token extraction (endpoints, methods, payload keys, `confirm=permanent`) is **identical** to Main's, count for count. |
| `app/(admin)/referrals/page.tsx` | promoted after logic diff | See §E. |

## E. Logic-preservation guard (per page)

Endpoints, HTTP methods, payload keys and `resource=` params were extracted and compared
Main-vs-demo for every redesigned page. Five pages flagged differences; **all five were
accounted for individually** and none was a behaviour change:

1. `banks/[id]` — DELETE endpoint reformatted across lines; URL string identical.
2. `parsers/page.tsx` — `.select(...)` column list wrapped; string byte-identical.
3. `parsers/[id]` — both endpoints present, URL strings identical; `window.confirm("Delete?")`
   became the consequence dialog (the approved dangerous-action change), request unchanged.
4. `announcements` — DELETE id now read from the confirm spec instead of a function argument,
   because the dialog replaced `window.confirm`. Same endpoint, method and id value.
5. `campaigns` — Main's separate `POST` collapsed into `method: editing ? "PATCH" : "POST"`.
   All three verbs still reachable; the added edit form reuses the **existing** PATCH contract.

**`qualified_in_cycle` appeared 5× in Main but 4× in the demo.** Investigated to the line: the
missing occurrence is Main's UI label `<Input label="New qualified_in_cycle" …>` — a raw
database column name shown to the operator, now Arabic. **The payload key
`qualified_in_cycle: Number(progress)` is present in both.**

H-13 machinery verified present in the promoted file: `createOperationIntent` ×3,
`operationIntentKey` ×5, `outcomeKnown` ×5, `crypto.randomUUID` ×1, `transportError` ×4,
`sessionStorage` ×2, and **4 `!outcomeKnown(r)` unresolved-outcome retry guards**. All eight
referral mutation endpoints reachable (`grant`/`extend` via the dynamic
`` `/api/entitlements/${action}` ``).

## F. Files deliberately excluded as demo-only

`lib/demo-guard.ts` · the `demo-guard` import in `lib/supabase.ts`, `lib/supabase-server.ts`,
`middleware.ts` · `.env.local` · `PROMOTION_MANIFEST.md` · `REDESIGN_INVENTORY.md`
(demo-session reports, not product source).

**Contamination sweep over all 9,660 promoted lines** — `127.0.0.1`, `localhost`, `192.168.`,
`qirsh-demo`, `demo.user@`, `demo.admin@`, `DEMO_LOCAL`, `demo-guard`, `Mailpit`, `5432x`,
`QirshDemo`, `supabase.co`: **0 hits each**.

## G. Main-only behaviour and files preserved

`admin/.env.local` (production config — untouched, and never used to run the server),
`admin/.env.local.example`, `admin/lib/operation-intent.mjs` and
`admin/tests/operation-intent.test.mjs` (both still untracked, unmodified), the staged
`tsconfig.tsbuildinfo` deletion, and all 113 non-Admin worktree entries.

## H. Residual differences between demo and promoted Main

Exactly the intended exclusions and nothing else:

```
Only in demo-docker/admin: PROMOTION_MANIFEST.md      (session report)
Only in demo-docker/admin: REDESIGN_INVENTORY.md      (session report)
Only in demo-docker/admin/lib: demo-guard.ts          (DEMO_ONLY)
Files ... lib/supabase.ts differ                      (demo-guard import only)
Files ... lib/supabase-server.ts differ               (demo-guard import only)
Files ... middleware.ts differ                        (demo-guard import only)
```

**Every UI file is byte-identical between the approved demo and Main.**

## I. Test changes (§20)

Six copy assertions were retargeted from English strings to the Arabic strings that now carry the
same meaning, plus one path change following the nav registry to `lib/nav.ts`. No structural or
security assertion was altered — the banned-vocabulary check
(`redemptions`/`sales`/`conversions`) is intact.

All eight Arabic assertion strings were confirmed to live in **rendered JSX, not comments**, and a
**negative control** was run: removing `مؤشرات استرشادية على التفاعل` from the page made test `AC`
fail (`pass 65, fail 1`); the file was then restored byte-identical
(`4b0885b8…`). The assertions cannot pass on source-only text.

---

## Validation results

| Check | Result |
|---|---|
| TypeScript typecheck | **exit 0** |
| ESLint | **no warnings or errors** |
| Admin tests | **66/66 pass, 0 fail, 0 skipped** (baseline was 65 pass / 1 skipped) |
| `Z2` built-bundle service-role test | **passes** — now runs, and did not at baseline |
| Production build | **exit 0**, 36/36 pages, all 15 routes present |
| `git diff --check` | clean |
| Route protection (unauth) | `/dashboard` `/referrals` `/coupons` `/flags` → 307 `/login`; `/api/coupons` `/api/referral-rules` `/api/admin-data` → 307 |
| Static assets (unauth) | brand PNGs 200 `image/png`; both TTFs 200 `font/ttf` |
| Visual smoke, 11 pages | RTL/ar, IBM Plex Sans Arabic, Qirsh logo, no overflow, **0 console errors** |

The smoke ran against the **local Docker demo backend** via shell env overrides on port 3002.
`admin/.env.local` points at the **production** project and was neither modified nor used to serve
traffic; every served chunk was confirmed to reference `127.0.0.1:54321` with **no production ref**.
The production build performs no data fetching (all Admin pages are `ƒ` dynamic).

## Out-of-scope findings — recorded, NOT fixed

Carried forward unchanged from `REDESIGN_INVENTORY.md`: `/categories/new` dead route;
feature-flag keys/descriptions are English **database content** (UI explains them in Arabic, the
stored values are untouched); the cold-dev-compile session observation. Main had not
independently fixed any of these.
