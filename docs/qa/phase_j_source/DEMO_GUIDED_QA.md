<!-- PROVENANCE: copied from `demo-docker/DEMO_GUIDED_QA.md`, which is an untracked local
     demo/working directory. The guided QA session log the findings originated from. Primary evidence for the UX-/F- identifiers.
     Tracked here so the authoritative artifact survives loss of that
     directory. The original is left in place; this copy is the one of
     record. -->

# DEMO_GUIDED_QA.md — Qirsh Guided End-to-End QA

Guided, one-step-at-a-time QA of Qirsh against the isolated Local Docker
environment plus the local Admin Dashboard.

**Environment**
- Workspace: `/Users/youssef/Documents/Money/demo-docker`
- Backend: Local Docker / Supabase only (`http://172.20.10.2:54321` over hotspot)
- Device: iPhone 13 / iOS 26.5 (`00008110-0001145E02EBA01E`)
- Admin: `http://localhost:3001`
- Financial PULL: DEMO_LOCAL verified-exact capability (overrides only)
- Financial PUSH: **PARKED** — not to be unparked before Phase 6 approval
- Main/Audit: READ-ONLY

**Rules in force:** no production/staging contact · no push/deploy · no remote
migrations · no automatic bug fixing without an explicit "fix it".

---

## Register

| Section | Count |
|---|---|
| PASS | 41 |
| FAIL | 2 |
| UX NOTES | 21 |
| BLOCKERS | 0 (1 remediated) |
| DEFERRED | 3 |
| PRODUCT FINDINGS | 6 |

---

## CHECKPOINT (2026-08-26)
**41 PASS · 2 FAIL · 6 product findings + F-008 (demo-config) · 17 UX notes · 3 CRs + SN-001**

Preserved corrections:
- Plan spending is derived from transactions within the plan's date range and accounts —
  it does **not** depend on `user_plan_transaction_links`. My earlier "should be zero" was wrong.
- F-005 stands as a real product finding: `show_on_header` is ignored by Home.

## PASS

- **Q00-01** Docker stack health — 8/8 intended containers up, 0 unhealthy, 0 restarting, Postgres accepting connections. Exclusions (postgres-meta/studio DF-001, logflare/vector DF-009) accepted.
- **Q17-02** Admin Banks page — **136 من 136** shown with an explicit count, all active, correct codes/countries/sender chips. Strong page: full-text search across name/code/**sender id**, country + status filters, and an in-UI explainer for «أرقام المُرسل».
- **Q17-01** Admin login + dashboard — `demo.admin@qirsh.test` authenticates, reaches `/dashboard`, and every headline figure matches Docker (2 users · 136 banks · 12 parsers · 21 categories · 26 flags / 3 active · 0 announcements).
- **Q05-04** Transaction detail (foreign currency) — every field matches Docker. Handles all three risk cases correctly: foreign amount surfaced as «بالعملة الأصلية: AED 349.00», null `balance_after` row **hidden** rather than rendered as 0.00, and the 0.88 parser confidence correctly kept internal.
- **Q05-02/03** Transaction filters & search — user reports all working. **Counts not itemised**, so recorded as user-attested rather than independently reconciled.
- **Q05-01** Transactions screen — richest screen so far and fully reconciled: **34 عملية للفترة** (مدى, آخر 90 يوم) · **1 قيد المراجعة** · إجمالي **5,682.65** = 5,827.65 − 145.00 pending ✅. All 34 rows render down to 2 July — **no cap here**, so F-009 is specific to account detail. Pending row **is** shown with a «قيد المراجعة» badge. UX-016 raised.
- **Q04-10** Accounts persistence after cold restart — everything unchanged (accounts, default badge, card ****4417, and the same 20-row cap), served from Drift.
- **Q04-02** Account detail — cards, transaction lists and every amount match Docker exactly for both الراجحي (6 txns) and مدى. **UX-013 escalated to HIGH**: the detail screen shows no balance either, so no screen in the app displays an account balance. UX-014/UX-015 raised.
- **Q04-01** Accounts list — all 4 seeded accounts present with correct names/types/currencies; مدى correctly badged «افتراضي»; icons distinctive. **UX-013 raised (no balances shown at all)** and **F-008** (an extra local-only account).
- **Q03-09** Home navigation — every route opens the correct screen (bottom nav ×5, «الكل» section links, «إدارة», «+»). **UX-012 raised:** the navigation icons are not legible — the user cannot tell where they lead.
- **Q03-08** Home loading / refresh — data renders **instantly from Drift** with no loading flash (user-confirmed), and every pull was a **delta-cursor** request (5/5, zero full pages, zero financial writes, server unchanged 57/4/3). **UX-011 raised:** no pull-to-refresh gesture exists.
- **Q03-07** Home empty states — نقداً/هذا الشهر shows 60.00 with a single transaction ✅ and budgets/subscriptions/goals correctly vanish. **Two defects surfaced:** F-006 confirmed in the opposite direction (0 → 60 shown as ↑100%), and **F-007** — the Plans section ignores the account filter entirely.
- **Q03-06** Home monthly/today summary — today's row correct (0.00/0.00/0.00, no transactions today); headline 2,120.00 correct. Comparison badge **proven week-over-week** (مدى: 382.40 vs 1,022.05 = −62.6% ≈ the −63% shown). **F-006 raised:** −100% shown when both periods are zero.
- **Q03-05** Home goals summary — goals are **account-scoped**, consistent with budgets/subscriptions/plans. With مدى the section is absent entirely; with الراجحي it shows صندوق الطوارئ 37% · تم توفير 18,500.00 · باقي 31,500.00 ✅ and STC — ألياف 399.00 «بعد 3 يوم» ✅ (due 29 Aug, today 26 Aug).
- **Q03-04** Home budget/subscriptions/plans sections — all values reconcile exactly. Plan رمضان spend **1,205.45** (1,404.45 confirmed debits − 199.00 refund) = 20% of 6,000 ✅, computed from in-range transactions on the plan's accounts even though `user_plan_transaction_links` is empty. Subscriptions correctly filtered to active-on-مدى (Netflix only). **F-005 raised:** `show_on_header` not respected.
- **Q03-03** Home recent-transactions list — order and values match Docker exactly for مدى/هذا الشهر (بنده 287.40 · أرامكو 95.00 · تميمي 164.90 · مطعم النخيل 118.50 · بنده 287.40 · Amazon.ae 356.25 · أرامكو 95.00 · تميمي 164.90). The **pending** row is omitted from the list as well as the total.
- **Q03-02** Home account selector — switching accounts recomputes the total correctly. مدى/هذا الشهر → 2,881.05 debits − 145.00 pending = **2,736.05** = app value. Budget ring appears (41% available) because all 3 budgets belong to مدى. UX-007 raised.
- **Q03-01** Home total — «إجمالي المصروفات» reconciles **exactly**: الراجحي/هذا الشهر → debits 2,319.00 − refunds 199.00 = **2,120.00**; الراجحي/هذا الأسبوع → **0.00** with only the salary credit listed. Scope = selected account **+** date range.
- **Q02-10** Cold-restart persistence — 57 transactions, 4 accounts, 3 budgets, 2 goals all present immediately after a full App-Switcher kill + relaunch. **0** password logins, **1** transaction pull and it used a **delta cursor** (0 full-page fetches), **0** financial writes. Drift is genuinely persistent; the app does not rebuild from the network.
- **Q02-09** Second pull / no duplicates — 57 held steady, 0 duplicates, delta-cursor pull, 0 financial writes.
- **Q02-08** Plans — data correct (ميزانية رمضان 6,000 active 15 Aug→14 Sep; مصاريف المدرسة 9,500 closed 25 Apr→25 Jul). Two UX gaps found: linked accounts not displayed, and the screen does not match the app design system.
- **Q02-07** Bill payments — 7 payments totalling 2,746.25 SAR, correct amounts/dates/instalment indices **and accounts** (6 on الراجحي = 2,690.25, 1 on مدى = 56.00). Consistent with `paid_count = 5` on the iPhone instalment.
- **Q02-06** Subscriptions & instalments — 4 items with correct amounts, due dates, statuses **and linked accounts** (STC 399 + iPhone 458.25 on الراجحي; Netflix 56 + gym 250 on مدى, gym paused). App does display the owning account per item.
- **Q02-05** Goals + contributions — both goals shown with correct figures (صندوق الطوارئ 18,500/50,000 · رحلة إسطنبول 4,300/12,000) and **5** contributions. The money invariant `saved_amount == SUM(contributions)` holds exactly.
- **Q02-04** Budgets initial pulled state — 3 budgets (2500/1200/900 SAR), progress 66%/42%/30%, header totals 4,600.00 budgeted · 2,379.80 spent · 52% · 3 budgets — all exactly matching Docker truth once account-scoping is applied. Planning-currency-gated entities pulled successfully.
- **Q02-03** Controlled server mutation → pull → Drift → UI — **the full chain proven end to end.** Server row date changed; app resumed; UI count went 56 → **57** and the salary appeared dated 24 Aug. Cursor advanced to exactly the mutated row; row UPDATED not reinserted; zero client financial writes.
- **Q02-02** Transactions initial pulled state — UI shows **56** of 57 server rows, ordering/merchants/amounts match, pending row present. The 1-row difference is the app **correctly filtering a future-dated transaction** that my seed created (F-003). App behaviour is right; the data was wrong.
- **Q02-01** Accounts initial pulled state — UI matches Docker truth exactly: 4 accounts, correct order/names/types/currencies, balances 18450.75 / -1240.50 / 365.00 / 712.25 SAR, total **18,287.50** SAR. Real pulled data, not a fixture.
- **Q01-08** Restart with existing session — opens straight to Home, **0** password logins (session restored from encrypted local storage), 1 clean boot cycle, 24 money-pull requests, **0** financial writes, `user_settings` still exactly 1 row with the merged name. F-002 fix survived a full sync cycle.
- **Q01-07** Onboarding state — `demo.user.onboarding_completed_at` set (20:48:06) and stable; `demo.admin` NULL (correct, never used the app); app routes straight to Home. The 4 repeated `mark_onboarding_completed` calls are harmless: the RPC is idempotent (`coalesce(onboarding_completed_at, now())`) and the timestamp never moved. Minor efficiency note only.
- **Q01-06** Authenticated session integrity — app requests bound to demo user only (1 distinct user_id), 0 requests under the admin identity, 208×200/20×201/11×204 with zero 401/403. App Settings shows "ليلى الحربي" / demo.user@qirsh.test (user-confirmed).
- **Q00-10** Financial PUSH parked — push capability NOT overridden (production default `unknown` intact); **0** client→server writes to any financial table despite an active session; server counts unchanged. App writes only non-financial rows (notification_logs, rpc, user_settings, profiles).
- **Q00-09** Seeded backend counts — 11/11 tables match exactly (4 accounts, 57 txns, 3 budgets, 2 goals, 5 contributions, 4 subs, 7 bill payments, 2 plans, 5 inbox, 7 categories, 2 cards). Both demo identities email-confirmed; admin_users = 1. Money invariants all clean (0 non-positive amounts, 0 bad currencies, 0 goal/contribution mismatches).
- **Q00-08** Demo guard fail-closed — shell guard live-tested: rejects all 3 protected refs + unknown hosted domain + arbitrary public host; accepts only the local LAN URL. Admin and App guard layers confirmed wired (import-time `assertDemoLocal()`; `_assertDemoLocalBackend` in bootstrap).
- **Q00-07** Zero hosted-Supabase contact — 0 live TCP connections, 0 forbidden-ref hits across all 8 container logs, 0 in all 4 runtime config files, workspace unlinked. The 2 hits in `realtime` were a Phoenix startup banner (`realtime.supabase.co`), not network contact; forbidden-ref count there = 0.
- **Q00-06** App backend URL — built with `SUPABASE_URL=http://172.20.10.2:54321`, `SUPABASE_ENV=local`, `DEMO_LOCAL=true`. Network topology (iPhone hosts hotspot .1, Mac is .2) makes that the only reachable address, and 644 requests landed on local kong. Evidence is topological, not a literal Host-header read (kong does not log it).
- **Q00-05** App running on device — `قرش` 0.1.3 (39) installed, Runner PID 1639 alive, 16 Dart requests in the last 5 min, session bound to demo user. User confirms app sits on Home with no errors.
- **Q00-04** iPhone hotspot connectivity — Mac en0 `172.20.10.2`, gateway `172.20.10.1` (the iPhone hosts the hotspot), device `connected` in Xcode, 644 live Dart requests reaching the local backend. Matches DF-007 trusted-network requirement.
- **Q00-03** Admin Dashboard — `next dev` on :3001, `/login` 200, all 9 admin routes 307-protected, bound to local Supabase with `NEXT_PUBLIC_DEMO_LOCAL=true`. Renders correctly (user-confirmed).
- **Q00-02** Local Supabase reachability — auth/rest/edge all HTTP 200 on both loopback and hotspot LAN (`172.20.10.2`); authenticated LAN read returned all 57 seeded transactions; Postgres responsive.

## FAIL

- **Q04-08 — account detail shows only 20 of 34 transactions.** See F-009.
- **Q05-09/10 — a refund is counted both as reduced expense and as income.** See F-010.

## UX NOTES

- **UX-006 (from Q02-08, observation — needs product decision):** the **closed** plan (مصاريف المدرسة) is shown in the main Plans list alongside the active one. Is that intended, or should closed plans move to a separate tab/filter/archive? Not recorded as a defect — needs a product call.
- **UX-016 (from Q05-01, user — MEDIUM):** **No filter for «قيد المراجعة».** The app surfaces the pending count twice — the Transactions header shows «1 قيد المراجعة», and Home shows a banner «1 عملية في انتظار مراجعتك — راجعها عشان أرصدتك تفضل مظبوطة» — yet the available chips are only الكل / مصروفات / دخل / تحويلات / التصنيف. The app asks the user to review pending items but provides no way to isolate them. Fine at 34 rows, impossible at 500. Suggest a «قيد المراجعة» chip and/or making the header count tappable.
- **UX-015 (from Q04-02, my observation):** the Cards section labels a card's origin as «يدوية» — an internal/technical term surfaced to the end user. Likely meaningless to a customer; either hide it or use plain language.
- **UX-014 (from Q04-02, my observation):** long account names are **truncated in the detail-screen title** — «الراجحي — الحساب ال...» while «مدى — البطاقة الرئيسية» fits. Needs marquee, wrapping, smaller type, or a shorter display form.
- **UX-013 (from Q04-01, escalated to HIGH in Q04-02):** **No screen in the app shows an account balance.** «الحسابات والمحافظ» lists only name + type + currency for each account. The balances exist and are correct in the data (الراجحي 18,450.75 · مدى −1,240.50 · نقداً 365.00 · STC Pay 712.25) but are never displayed. Combined with Home showing *expenses* rather than a balance, **no screen in the app currently answers "how much money do I have?"** — the most basic question a finance app must answer, and the first thing a client will ask in a demo. Also blocks any check of how a negative balance is presented.
- **UX-012 (from Q03-09, user):** **«الأيقونات مش واضحة»** — the bottom-navigation icons do not communicate their destinations. Routing is functionally correct, but the user cannot tell from the glyphs where each tab goes. Candidates for redesign: the «الأشكال»-looking glyph, the wallet, and the receipt icons. Consider clearer metaphors and/or **text labels under the icons** (the reference app «وفير» labels every tab: الرئيسية / تنبيهات / عروض / حسابي). Severity: MEDIUM (navigation comprehension).
- **UX-011 (from Q03-08, user):** **No pull-to-refresh on Home.** Data does refresh on resume/cold start, but there is no manual gesture to force it. Users expect swipe-down-to-refresh on a financial dashboard, and during a demo there is no way to visibly trigger a sync on command. Suggest adding pull-to-refresh that runs the normal sync path (not a bespoke one).
- **UX-010 (from Q03-05, my observation):** Home sections **disappear silently** when the selected account has no matching data — no header, no empty state, no explanation. Switching الراجحي → مدى makes the whole «الأهداف» section vanish; switching back makes «الميزانية» vanish. A user who had goals on one account and switches will think something broke. Suggest an explicit empty state («لا توجد أهداف على هذا الحساب») or keeping the header with a hint. **Tightly coupled to UX-007** — if the selector named the active account, the disappearance would be self-explanatory.
- **UX-009 (from Q03-03, my observation):** the floating bottom nav bar **overlaps list content** — the مواصلات budget row was partially hidden behind it (its limit digits were covered). Needs bottom padding / safe inset so the last rows are fully readable.
- **UX-008 — APP LOGO IN THE HOME HEADER** (from Q03-03, user request): «عايز أحط الأيقونة بتاعة التطبيق من فوق كده خالص في المكان اللي عاملك عليه دايرة زي باقي التطبيقات». Place the Qirsh brand mark / app icon in the empty area at the top of the Home header (left of the greeting «مرحباً ليلى الحربي», right of the «+» button), the way other apps present their identity.
- **UX-007 — HOME ACCOUNT SELECTOR DOES NOT NAME THE SELECTED ACCOUNT** (from Q03-02, user-approved): the chip reads «حساب ريال» **regardless of which account is active** — it still said «حساب ريال» after switching from الراجحي to مدى. Since every headline figure on Home is scoped to the active account and changes drastically between accounts (2,120.00 vs 2,736.05), the user cannot tell which account the numbers describe. **Information gap, not styling.** Suggest showing the actual account name (and ideally its icon) in the chip. Severity: MEDIUM (product UX).
- **UX-005 — PLANS SCREEN: DESIGN DOES NOT MATCH THE APP** (from Q02-08, user): «شكل الصفحة عايزه يطابق design الـapp». Screen-specific redesign so the Plans screen visually belongs to the same design system as the rest of the app. Preserve all data/behaviour.
- **UX-004 — PLANS: LINKED ACCOUNTS NOT DISPLAYED** (from Q02-08, user): «الحساب المرتبط مش ظاهر». Each plan is bound to one or more accounts in the data (ميزانية رمضان → مدى + الراجحي; مصاريف المدرسة → الراجحي) but the UI shows none of them. **Inconsistent with the Subscriptions screen (Q02-06), which does surface the owning account.** This is an information gap, not just styling — the user cannot tell which accounts a plan covers. Severity: LOW–MEDIUM (product UX).
- **UX-003 — BUDGET BOTTOM SHEET: FULL REDESIGN REQUIRED** (from Q02-04, user; product decision confirmed)
  - **Not a colour-only fix.** The user does not like the current bottom-sheet design.
  - Requires a complete visual/UX redesign: layout, hierarchy, spacing, typography,
    cards/sections, actions, progress presentation, colours, and overall interaction feel.
  - It must visually belong to the same design system as the rest of the app.
  - **Preserve all existing functionality, calculations, actions and data behaviour.**
  - Status: OPEN — deferred to the consolidated redesign pass. NOT fixed.
- **UX-002 — HARDCODED BLACK/WHITE TREATMENT: REDESIGN REQUIRED** (from Q02-04, user; product decision confirmed — Option B)
  - The user does **not** want the hardcoded black/white visual treatment.
  - Replace it with the actual **Mali/Qirsh product visual identity and brand colours**.
  - **App-wide design rule**, not a Budgets-screen issue.
  - First instances observed: the black promo banner «وزّع دخلك على المظاريف» and the black
    selected tab chip «الميزانيات» on the Budgets screen.
  - **Collection rule for the rest of QA:** whenever the same black/white treatment is found on any
    screen, record it **under UX-002** — do not open duplicate findings.
  - **Constraint:** do NOT blindly make everything blue. Preserve hierarchy, contrast,
    accessibility, light/dark behaviour, and semantic states (success/warning/danger).
  - Status: OPEN — deferred to the consolidated redesign pass. NOT fixed.
- **UX-001 (from Q02-04, my note):** كروت الميزانيات تعرض المبالغ **مقرَّبة لريال صحيح** (1,644 بدل 1,644.30 · 356 بدل 355.50) بينما هيدر نفس الشاشة يعرض الهللات (2,379.80). القيم الدقيقة سليمة في القاعدة؛ الملاحظة عرضية/اتساقية فقط.
- **N-004 (LOW, accuracy/documentation, product):** My earlier phrasing "0 financial writes" was literally true but incomplete. The app calls `rpc/set_default_account` (**4×**), which mutates `user_accounts.is_default` server-side — it did not appear in my POST/PATCH/DELETE table-write check because it goes through an RPC. This is **not** a breach of the push gate: `exactPush` governs money-value transport, and this changes a non-monetary attribute. Correct wording is "the app writes no monetary values", not "the app writes nothing to financial entities". Effect: the seeded default (الراجحي) was replaced by مدى; the `uidx_user_accounts_one_default` unique index keeps exactly one default, so data stays coherent. Not remediated.
- **N-003 (LOW, product efficiency, from Q01-08):** `user_settings.revision` moved 3 → 5 during a single app restart with **no** user-visible settings change — i.e. the app rewrites the settings row ~twice per launch without a real diff. Same pattern as the repeated `mark_onboarding_completed` calls (Q01-07). Not a functional defect (values stay correct, convergence works), but it inflates `revision` and widens the CAS-conflict window across multiple devices. **Not remediated during guided QA, by user decision.**
- **N-002 (LOW, technical, from Q00-03):** Admin dev-server log shows 21× `Syntax error: admin/app/globals.css — The 'bg-canvas' class does not exist`, plus some `/_next/static/chunks/fallback/*` 500s. The `canvas` colour IS defined in `tailwind.config.ts`. User confirmed the UI renders fine, so **no visible impact**; kept in the register as a low-severity build-noise item. NOT fixed (finding policy).
- **N-001 (operational, from Q00-01):** Disk at 5.12 GiB is acceptable for QA, but **no automatic iOS rebuilds**. If a finding requires a rebuild, STOP first and report expected disk cost + current free space. — standing rule for the rest of this session.

## BLOCKERS

### F-001 — [REMEDIATED_DEMO_ONLY] Debug build cannot be launched from the iPhone home screen
- **Severity:** BLOCKER (for standalone/demo use); **not** an app-logic defect
- **Class:** iOS / Flutter build-mode constraint (demo packaging decision)
- **Screen:** cold launch from home screen
- **Steps to reproduce:** force-close Qirsh from App Switcher → tap the app icon
- **Expected:** app launches, restores session, shows Home
- **Actual:** process starts then dies with `signal 11` (SIGSEGV)
- **Evidence (captured from the device via `devicectl … --console`):**
```
Cannot create a FlutterEngine instance in debug mode without Flutter tooling or Xcode.
To launch in debug mode in iOS 14+, run flutter run from Flutter tools, run from an IDE
with a Flutter IDE plugin or run the iOS project from Xcode.
Alternatively profile and release mode apps can be launched from the home screen.
Flutter application in debug mode can only be launched from Flutter tooling.
App terminated due to signal 11.
```
- **Why it worked before:** the app was launched *by* `flutter run`, which creates the
  FlutterEngine for it. It kept running for hours after the tool exited (644+ requests).
  Only a NEW launch from the icon fails, because the engine can no longer be created.
- **Not caused by:** backend (LAN health 200, 8 containers up), DEMO_LOCAL guard, Supabase
  init, Drift, auth/session (0 token requests — session restored locally), or the exact-transport
  overrides. None of that code is reached; the engine never initialises.
- **Proposed smallest fix:** rebuild once in **profile** mode instead of debug.
  `kReleaseMode` is false in profile, so (a) `bootstrap_runner`'s production guard still
  returns early and does not throw, and (b) the demo capability overrides still install —
  while profile/release builds *can* launch from the home screen.
- **Status: REMEDIATED_DEMO_ONLY** (2026-08-26 01:00)
- **Remediation:** rebuilt and installed in **PROFILE** mode via `tools/demo_build_profile.sh`
  (`flutter build ios --profile` + `devicectl install` — deliberately NOT `flutter run`, so no
  tooling stays attached). Production authority untouched; push still parked.
- **Why profile is correct:** `kReleaseMode` is FALSE in profile, so `bootstrap_runner`'s
  production guard still returns early (does not throw) and the demo PULL capability still
  installs — while profile/release builds CAN launch from the home screen.
- **Honest caveat:** the demo capability is therefore also active in a profile build, not only
  debug. Profile builds are not App-Store distributable and the release guard still protects
  production, so this is acceptable — but it is a slightly wider surface than debug-only.
- **Verification:** device console shows **0** `Cannot create a FlutterEngine` and **0** `signal 11`
  (previously 4 and 1). Cold launch from icon: app opens and stays open, goes straight to Home.
  180 Dart requests, **0** password logins (session restored locally), 48 money-pull requests,
  **0** financial writes. `flutter`/`dart` not running → standalone launch proven.
- **Artifact:** 70 MB profile Runner.app (vs 206 MB debug). Build min free 7.01 GiB (floor 3).

## DEFERRED

- **D-003 — AUTH/LOGOUT/LOGIN BLOCK deferred as one unit:** Q01-02 (login screen), Q01-03
  (demo-user login), Q01-04 (wrong password), Q01-09 (network interruption during login) and
  Q01-10 (logout) are deferred together and will be executed as a single block later. Reason:
  all require an unauthenticated state; signing out now risks wiping local Drift and losing the
  pulled dataset. Device stays authenticated; Drift preserved.
- **D-002 — Q01-02 login screen: DEFERRED_TO_Q01-10** (not skipped, not passed). The session is
  currently authenticated and the app routes straight to Home, so the login screen is not
  reachable without logging out. Deliberately NOT logging out now, to preserve the pulled Drift
  dataset. Q01-02/03/04/09 will be executed in their natural state immediately after Q01-10
  (logout), which lands on the login screen.
- **D-001 (deferred evidence, from Q00-08):** Negative *runtime* guard tests for the **Admin** and **App** layers (i.e. actually building them against a remote URL and observing the fail-closed throw). Both are proven by code wiring, not by live negative execution. Deferred by user decision — exercising them would require unnecessary rebuild/config churn, and **no iOS rebuild is to be done for this**. Not a failure.

### F-010 — [OPEN · PRODUCT · **MOBILE-ONLY**] Refunds are double-counted
**Final classification: mobile-only accounting aggregation defect — server truth is correct.**
: subtracted from expenses AND listed as income
- **Severity:** MEDIUM · **Class:** PRODUCT (accounting consistency) · **Discovered during:** Q05-09/10
- **Evidence — the same 199.00 SAR refund («نون», `transaction_type = 'refund'`) is treated twice:**
  | surface | treatment | proof |
  |---|---|---|
  | Home total | **subtracted from expenses** | Q03-01: 2,319.00 − 199.00 = **2,120.00** ✅ reconciled |
  | Transactions «دخل» filter | **counted as income** | screenshot: 4 rows returned — 3× salary 16,500.00 **plus نون +199.00** |
- **Neither treatment is wrong on its own** — reducing the expense (contra-expense) and booking it
  as income are both defensible. The defect is doing **both simultaneously**, so the user benefits
  from the same 199.00 twice: expenses fall by 199 *and* income rises by 199, a 398 swing from a
  199 event.
- **Corroborating signal:** the row is displayed under the **«تسوق»** category — the app itself
  classifies it as a shopping transaction, not an income source.
- **Impact:** any income report or income-vs-expense comparison is inflated by the value of refunds.
- **Expected:** pick one treatment. Either exclude `refund` from the «دخل» filter (if Home's
  contra-expense model is authoritative), or stop subtracting it on Home — not both.
- **Retrospective:** this explains why reconciling the Home figure in Q03-01 took eleven attempts —
  the refund rule is not applied uniformly across the app.
- **LAYER ISOLATED (Q17 pre-check, 2026-08-26):** the responsibility is **entirely in the mobile
  app**.
  - **Server data:** `transaction_type = 'refund'` is its own type. Neutral, correct.
  - **Server aggregation:** `monthly_financial_summary` returns four **separate** buckets —
    verified live for الراجحي/August:
    ```json
    { "income": 16500.0, "refund": 199.0, "expense": 2319.0, "transfer": 0 }
    ```
    Income **excludes** the refund; expense is **gross** (not netted). The server states three
    distinct facts and leaves interpretation to the consumer. **Correct and unambiguous.**
  - **Mobile app:** applies two *contradictory* interpretations of its own — Home nets the refund
    off expenses (2,319 − 199 = 2,120) while the «دخل» filter adds it to income.
  - **Contributing factor:** the app does not consume this RPC at all —
    `MALI-063n: every total comes from the canonical Drift aggregates (the dormant Supabase summary
    path is retired)`. Totals are computed locally from Drift, so there is no single reconciled
    source, which is how the contradiction survived unnoticed.
  - **Fix belongs in the app**, and the product decision is whether to adopt the server's
    three-bucket model or settle on one interpretation.
- **Status:** OPEN — layer isolated, not fixed.

### F-009 — [OPEN · PRODUCT] Account detail caps at 20 transactions with no way to see the rest
- **Severity:** MEDIUM · **Class:** PRODUCT · **Discovered during:** Q04-08
- **Root cause (confirmed in code):**
  ```dart
  // lib/features/accounts/accounts_providers.dart:14
  .getRecent(limit: 20, accountId: accountId);
  ```
  A hard-coded limit of 20.
- **Evidence:** مدى holds **34** transactions; the account detail screen renders **20**.
  **14 transactions are unreachable** from that screen — there is no pagination, no infinite
  scroll and no «عرض المزيد» action.
- **Context:** `cards_providers.dart` uses `limit: 500`, so 20 is a screen-specific choice rather
  than a global convention.
- **Mitigating:** the section is titled «آخر العمليات» (recent), which softens the expectation —
  but it does not solve it, because no path to the remaining rows exists anywhere on the screen.
- **Scope narrowed (Q05-01):** the dedicated Transactions screen renders **all 34** rows down to
  2 July with no cap, so this is **specific to the account-detail screen**, not a global pattern.
- **Precedent for the fix (Q17-02):** the Admin Banks page displays **«136 من 136»** — an explicit
  "showing X of Y" indicator. The correct pattern already exists in the product; F-009 is an
  inconsistency with an established pattern rather than a missing design.
  Natural fix: have «آخر العمليات» on account detail link into the Transactions screen pre-filtered
  by that account.
- **Status:** OPEN — recorded, not fixed.

### F-008 — [OPEN · DEMO-CONFIG, not a product defect] Local-only account absent from the server
- **Severity:** INFO · **Class:** consequence of financial PUSH being parked
- **Discovered during:** Q04-01
- **Evidence:** the app lists **5** accounts — مدى · الراجحي · **الحساب الرئيسي** · نقداً · STC Pay —
  while the server has only the **4** seeded ones. Confirmed: `0` client writes to `user_accounts`,
  and no row named «الحساب الرئيسي» exists on the server (not even soft-deleted).
- **Cause:** the app creates a default local account on first run
  (`app/CLAUDE.md`: "v2 migration creates a default account and backfills"). With PUSH parked it
  can never reach the server, so it lives only in Drift.
- **Not a product defect** — it is exactly what a parked push implies.
- **Demo impact:** comparing the app against the Admin dashboard in front of the client will show
  one extra account in the app.
- **Useful:** this is the natural first row to exercise when we test PUSH in Phase 6.
- **Status:** OPEN — recorded, no action.

### F-007 — [OPEN · PRODUCT] Home Plans section ignores the selected account
- **Severity:** MEDIUM · **Class:** PRODUCT (scoping inconsistency)
- **Discovered during:** Q03-07 (empty-state test)
- **Evidence:** «ميزانية رمضان» is bound to `server_account_ids = {الراجحي, مدى}` — **نقداً is not
  among them** — yet with نقداً selected the plan still appears on Home, showing the **same**
  spend figure **1,205.45**, i.e. money from other accounts entirely.
- **Scoping is inconsistent across Home:**
  | section | account-scoped? |
  |---|---|
  | الميزانية | ✅ yes |
  | الاشتراكات | ✅ yes |
  | الأهداف | ✅ yes |
  | **الخطط** | ❌ **no** |
- **Impact:** a user on one account sees a plan that does not belong to it, with figures drawn from
  other accounts — misleading, and inconsistent with the rest of the screen.
- **Correction to my own earlier conclusion:** in Q03-05 I wrote that Home scoping was "fully
  consistent across budgets, subscriptions, goals and plans". That was wrong — I generalised from
  three sections without testing the fourth. This empty-state test exposed it.
- **Status:** OPEN — recorded, not fixed.

### F-006 — [OPEN · PRODUCT] Comparison badge reports −100% when both periods are zero
- **Severity:** LOW–MEDIUM · **Class:** PRODUCT (calculation / empty-data handling)
- **Discovered during:** Q03-06
- **Evidence:**
  - الراجحي — this week **0.00**, previous week **0.00** → app shows **«↓ 100% عن الأسبوع الماضي»**
  - and the weekly summary card states **«أحسنت — مصروفك أقل بـ100% عن الأسبوع اللي فات»**
- **Expected:** zero vs zero is **no change (0%)**, or "not enough data to compare" / hide the badge.
- **Actual:** a 100% decrease is claimed, and the user is congratulated for a saving that did not
  happen. Likely a divide-by-zero path resolving to −100% instead of an "no comparison" state.
- **Comparison logic itself is correct:** verified week-over-week against مدى —
  (382.40 − 1,022.05) / 1,022.05 = −62.6% ≈ the −63% displayed ✅. **I withdraw my earlier
  suspicion that the «عن الأسبوع الماضي» label was misleading** — the label is accurate; only the
  zero/zero case is wrong.
- **Confirmed in BOTH directions (Q03-07):** نقداً — this week **60.00**, previous week **0.00** →
  app shows **«↑ 100%»**. Going from zero to 60 is an unbounded increase, not +100%. The weekly
  card then warns **«انتبه — مصروفك أعلى بـ100% … راجع أكتر فئة بتصرف فيها»** — an alarming
  message derived from an invalid comparison over a single 60 SAR transaction.
- **Demo relevance:** very likely to appear — any freshly-selected account or quiet period hits it.
- **Status:** OPEN — recorded, not fixed.

### F-005 — [OPEN · PRODUCT] `show_on_header` is ignored by the Home budget section
- **Severity:** LOW–MEDIUM · **Class:** PRODUCT · Not demo-only
- **Discovered during:** Q03-04
- **Data:** `groceries.show_on_header = true`, `restaurants.show_on_header = true`,
  **`transport.show_on_header = false`**
- **Expected:** Home's «الميزانية» section shows only budgets flagged for the header (بقالة، مطاعم).
- **Actual:** all three are shown, including **مواصلات** whose flag is `false`
  (screenshot: مواصلات 42% · مطاعم 30% · بقالة 66%).
- **Impact:** the user cannot control which budgets surface on Home; the column is written and
  pulled but never consulted for presentation.
- **Not a demo artifact:** the flag values are correct in the database and were pulled correctly.
- **Status:** OPEN — recorded, not fixed.

### F-004 — [OPEN · PRODUCT · LOW] `set_default_account` performs a redundant write
- **Severity:** LOW · **Class:** PRODUCT (RPC write behaviour) · Not demo-only
- **Scope:** narrow and independently proven. See the RETRACTION below.

**The finding**
`set_default_account` (migration 0025) promotes unconditionally:
```sql
update public.user_accounts set is_default = true
where id = p_account_id and user_id = auth.uid();   -- no "is distinct from true" guard
```
When the requested account is **already** the default, the row is still written, so
`trg_user_accounts_revision` fires and `revision` increments for no reason.

**Proof (independent of the app and of any user action):** I called the RPC directly over
PostgREST with the account that was already default. Result: الراجحي `revision 13 → 14`,
`is_default` unchanged, every other row untouched. Logically idempotent, not storage-idempotent.

**Impact:** unnecessary `revision` growth, which theoretically widens the CAS-conflict window.
No data corruption, no money involvement, **no demo risk**.

**Suggested remediation (recorded, not selected by Demo Crowd):** guard the promote UPDATE, e.g.
`... and is_default is distinct from true;` — a forward migration that benefits every caller.

**Test needed:** calling the RPC with an account that is already default must not move `revision`.

---

#### ⚠️ RETRACTION — earlier F-004 conclusions were WRONG
An earlier version of this finding claimed the default account **oscillated on its own** between
مدى and الراجحي, and built a wider theory on top of that: server-vs-Drift authority conflict,
`_ensureOneDefaultAccount()` re-picking `sort_order = 0`, unconditional `_resolveDefault()`
re-assertion every sync, multi-device ping-pong, revision inflation, and a risk of the highlighted
account flipping mid-demo.

**All of that is retracted.** The user was changing the default **manually from the app's Accounts
screen** during QA, and the UI updated correctly every time.

**My error:** I asserted "without user action" from log evidence alone instead of asking whether
the user had changed it. Every account change and every revision increment observed during QA is
explained by that intentional switching (each real switch writes two rows — promote + demote).

Retracted and NOT to be handed to Audit/Main:
- autonomous default-account oscillation
- server-vs-Drift authority conflict
- `_ensureOneDefaultAccount()` fallback firing in practice
- unconditional per-sync re-assertion as an observed behaviour
- multi-device ping-pong
- any demo-presentation risk
- the proposed severity upgrade to HIGH

The **only** surviving item is the redundant-write behaviour above, proven by direct RPC call.

### F-003 — [FIXED_DEMO_ONLY] Seed creates a future-dated salary transaction
- **Severity:** LOW · **Class:** demo seed data (NOT a product defect)
- **Discovered during:** Q02-02
- **Steps to reproduce:** run `tools/demo_seed.sql`, then compare `select count(*) from user_transactions`
  (57) with the count shown on the app's Transactions screen (56).
- **Expected:** every seeded transaction dated in the past.
- **Actual:** one salary row dated **2026-08-28**, two days in the future (today 2026-08-26).
  Cause: the seed computes `date_trunc('month', now()) - (m months) + interval '27 days'`,
  so for the current month that lands on 1 Aug + 27 days = 28 Aug.
- **Evidence:** `select count(*) … where occurred_at > now()` → 1.
- **App behaviour is CORRECT:** it filters the future-dated row, hence 56 on screen vs 57 in the
  database. This was predicted before the user looked, and confirmed.
- **Demo impact:** a future-dated salary would sit at the top of the list and can distort
  "income this month" if any screen counts it. Visible to a client.
- **Status: FIXED_DEMO_ONLY** (2026-08-26 01:24), fixed in BOTH places:
  1. **Seed source** — `tools/demo_seed.sql` now clamps the salary date:
     `least(date_trunc('month',now()) - (m||' months')::interval + interval '26 days',
            date_trunc('day', now() - interval '1 day'))`
     so a seeded salary can never be future-dated on any reset date.
  2. **Live DB** — updated ONLY `occurred_at` on row `8afc35e0-b4ae-4e99-83b4-8a41ed197d5a`
     (2026-08-28 → 2026-08-24). No reset/reseed. amount, currency, direction, type, category,
     merchant, description, account and id all untouched.
- **Doubled as the Phase-2 controlled-mutation proof — see Q02-03.**

### F-002 — [FIXED_DEMO_ONLY] Duplicate/orphaned `user_settings` row from the demo seed
- **Severity:** LOW · **Class:** demo seed data (NOT a product defect, no constraint violated)
- **Discovered during:** Q01-07
- **Cause:** the seed used an arbitrary `local_id='settings-demo-user'`, but the app's canonical
  singleton key is `local_id='user_settings'`
  (`planning_outbox_queue.dart: static const String settingsLocalId = 'user_settings'`).
  The unique key is `(user_id, local_id)`, so a second row was legal — and the app **pulls**
  `user_settings` (43 GETs observed), so it ingested the orphaned row.
- **Correction to my first assessment:** I initially assumed the app only *pushed* settings.
  It pulls them too, which is why the seeded name appeared in the UI.
- **Fix applied (data):** merged the demo display values (name/theme/currency/language/country)
  into the canonical row while **preserving the app-written consent flags**
  (`privacy_mode=f`, `ai_consent=t`, `cloud_processing=t`), then deleted the orphan. revision 2→3
  so the app pulls it as newer.
- **Fix applied (seed):** `tools/demo_seed.sql` now uses `local_id='user_settings'` with
  `on conflict (user_id, local_id) do update`, so a re-seed converges instead of duplicating.
- **Verified:** upsert run twice → still exactly **1** row; values coherent; all 11 other demo
  tables unchanged (4/57/3/2/5/4/7/2/5/7/2); 0 rows with the old local_id.
- **Scope:** demo-docker only. No product code, schema, migration, or Main/Audit change.

## PRODUCT FINDINGS

Carried in from the environment build (see `DEMO_FINDINGS.md`):
DF-001 · DF-002 (HIGH, product) · DF-003 · DF-004 · DF-005 · DF-006 · DF-007 ·
DF-008 · DF-009.

---

## PHASE 6 — FULL FINANCIAL PUSH / WRITE VERIFICATION (deferred queue)

**Decision (user, 2026-08-26):** every financial write test is deferred out of the read-only QA.
While PUSH is parked a write would land in local Drift only, proving half the truth and
accumulating pending rows that would confuse the later push results.

**Deferred into this queue:** Q04-03 (create account) · Q04-04 (edit account) · Q04-07
(delete/archive) · **and every equivalent financial-write test in later phases** (transactions,
budgets, goals, planning, subscriptions).

**Each deferred write is executed as a complete end-to-end chain:**
`UI action → Drift write → outbox/intent → real PUSH → server exact state → ack/sync_status →
pull-back → UI reconciliation`

**Each write stays isolated and must verify:**
- exact money (to the minor unit)
- no duplicate row created
- idempotent retry
- server row count and state
- Drift ↔ server identity mapping
- pull-back consistency
- correct account ownership
- **no unexpected bulk upload of unrelated pending rows**

### MANDATORY PRE-CONDITION before enabling PUSH
Inventory **every** pending local financial row first — including the existing
**«الحساب الرئيسي»** fixture (F-008) — so we know exactly what would be transmitted.
**Phase 6 must not auto-flush unknown pending rows.** The list is produced, reviewed and
explicitly approved by the user before PUSH is enabled.

## THREE RUNNING REGISTERS (user, 2026-08-26)

Maintained separately for the rest of QA:
1. **Product Findings** — real behavioural/logic defects (F-001…F-005).
2. **UI/UX Redesign Backlog** — `UI_UX_REDESIGN_BACKLOG.md` (UX-001 onward).
3. **Client Change Requests** — CR-001 onward (Home restructuring; «وفير» as *inspiration/patterns
   only*, never a copy).

No UI fixes or redesign during QA unless the user explicitly stops QA and authorises it.
Visual/UX comments are recorded on **every** screen, even when the functional test passes.
After QA completes: one consolidated redesign pass, then regression-test the affected flows.

### SN-001 — PRODUCT SCOPE NOTE: Admin exposes catalog/config/growth only
*(The user referred to this as "CR-003 / PRODUCT SCOPE NOTE"; CR-003 was already assigned to
«برامج السفر والقطة», so this is filed as **SN-001** to avoid collision. Both are preserved.)*

The Admin Dashboard currently exposes **catalog, configuration and growth operations only** —
dashboard · banks · parsers / parser-lab · categories · flags · referrals · coupons · campaigns ·
announcements. It provides **no end-user financial-data views**; the code contains zero references
to `user_transactions`, `user_accounts`, `user_goals` or `user_budgets`.

**This is NOT classified as a defect** — no existing requirement states the Admin must expose user
financial data. Consequence for QA: app-vs-Admin cross-validation of financial figures is not
possible; direct LOCAL Docker SQL is used as the independent truth source instead (and is in fact
stronger — raw data with no presentation layer).

If the client later asks for financial-user visibility in Admin, that is a **new feature request**
requiring its own privacy and authorization design, not a bug fix.

### CR-003 — «برامج السفر والقطة» · **CLARIFICATION_REQUIRED**
Mentioned by the client as a Home section. **Not inferred, not designed, not assumed.** No such
feature exists in the current product or database. Held until the user explains exactly what is
meant.

### CR-004 — Per-user report history + configurable generation limits · **REQUESTED / NOT IMPLEMENTED**

**Client request (2026-08-27):** Qirsh must be able to show how many reports each user has
generated and enforce a configurable allowance (for example, a defined number of reports per
user and period). The allowance must be controllable as a real product rule, not inferred from
anonymous analytics.

**Current proven gap:**

- there is no `user_reports`, `report_history`, or equivalent owner-bound table;
- generated report files are local/temporary rather than durable server records;
- `metrics` has no `user_id`, so it cannot answer a per-user question;
- the client emits report-export metric names, but `record_metric` currently allowlists only
  `app_open`, so report metrics are silent no-ops; and
- the current local database contains zero report-related metric rows.

**Required product semantics for later design:**

1. Server-authoritative, owner-bound usage count; the client must not be able to set/reset its
   own total.
2. Configurable quota by entitlement/plan and time window (for example daily, monthly, or billing
   period), with an explicitly defined reset boundary and timezone.
3. Count only a successfully generated report; preview retries, failed generation, duplicate
   requests, sharing, and printing must not accidentally consume additional generation quota.
4. Stable operation/idempotency key so retries cannot double-count.
5. Atomic server-side `check allowance -> reserve/record success` behaviour to prevent concurrent
   requests exceeding the limit.
6. Admin visibility into per-user usage and the effective rule, with separately authorised and
   audited override/reset actions if those are later required.
7. Store minimum metadata only: `user_id`, report type/scope, status, generated timestamp,
   period/rule reference, and operation id. Do **not** store the generated PDF or raw financial
   contents merely to enforce quota.
8. Clear app UX showing allowance/remaining count and a deterministic limit-reached state.
9. Account deletion/retention and privacy requirements must cover this history explicitly.

**Status:** recorded for consolidated product design. No schema, database, Admin, app, metric,
or entitlement change was made during guided QA.

### CR-005 — Date of birth in profile/settings UI · **REQUESTED / NOT IMPLEMENTED**

The user reports that date of birth is not exposed in the current app UI. Add a deliberate,
privacy-reviewed profile field and edit flow only if the product has a defined use for it; do not
collect DOB merely because the backend can store another attribute. Define optionality, age rules,
retention, account export/deletion behaviour, and whether Admin is ever allowed to see it.

### CR-006 — Consent choices during onboarding · **REQUESTED / PRODUCT SEMANTICS REQUIRED**

Cloud processing and AI consent are not presented during onboarding. The user wants these choices
explained there rather than discovered later in Settings. Current behaviour couples them: turning
cloud processing OFF also turns AI consent OFF. That dependency may be privacy-safe (AI processing
cannot remain active when its required cloud transport is disabled), so it is **not classified as
a defect without a revised authority/consent model**. The redesign must distinguish prerequisite,
consent and current availability, preserve revocation, and never imply that AI can process data
when cloud processing is disabled.

### CR-007 — Phone country code / number-entry redesign · **REQUESTED / NOT IMPLEMENTED**

Add an explicit country-dial-code selector/prefix in the phone-number entry area instead of an
ambiguous generic number field. Define country source, formatting, validation, RTL behaviour and
international numbers; do not infer a dial code solely from app language.

### CR-008 — Production-grade AI capability in Qirsh · **REQUESTED / DISCOVERY REQUIRED**

The current AI result quality is not good enough for the user. Requested direction: integrate a
capable model/provider (Gemini was mentioned as an example) into the real Qirsh capture/parsing
experience. This is not approval to add a provider or secret during Demo Crowd. Later design must
define exact tasks, quality/evaluation corpus, deterministic financial validation, consent,
privacy/data residency, cost/rate limits, fallback, observability and fail-closed behaviour. AI
must not become financial authority or fabricate exact-money fields.

### CR-009 — iOS Shortcut/capture quality improvement · **REQUESTED / NOT IMPLEMENTED**

The user reports that the iOS Shortcut flow is not reliable/good enough and expects improved
parsing once the app AI pipeline is mature. The requested UX also includes showing the resolved
category in the resulting notification. Preserve consent and local-only/demo boundaries; do not
claim APNs verification from a local notification.

## USER-LED FEATURE SWEEP — 2026-08-27

### User-confirmed working coverage

- User Accounts: create, edit and delete completed.
- Account Transactions: completed.
- Subscriptions: completed, including close/reopen persistence.
- User Cards: core create/edit flow completed (separate UX/data-integrity notes remain below).
- User Goals: completed.
- Notifications: generally reported good, except the scoped budget/Shortcut message findings.
- Settings: theme control is present and working.

### SN-002 — Automatic plan scope versus explicit transaction links

The user observed that transactions automatically included by selected plan accounts/cards affect
the plan calculation but do not appear in `user_plan_transaction_links`; manually using «ربط
عملية» does create a link row. This is recorded as a **scope/communication note, not a defect**:
the established model derives automatic plan spending from transactions in the relevant account
scope, while the link table represents explicit/manual links. Product/UI must explain that
distinction. If the intended requirement is to materialise every automatically scoped transaction
as a durable link, that is a separate architecture change and needs explicit confirmation.

## REPORTING RULE (user, 2026-08-26)

For **every** test from Q02-06 onward, the expected-values table must name the **account each row
belongs to** (e.g. Netflix sits on the مدى card account). The user needs to see which account an
item will be charged against, not just the amount.

## WORKFLOW DECISION (user, 2026-08-26)

Guided QA is **not** paused to implement UI changes. For every screen:
1. verify functionality/data first,
2. ask the user for visual/product feedback,
3. record each UX finding precisely,
4. **do not remediate** unless it blocks further testing,
5. move to the next test.

At the end of the guided QA, produce a consolidated **UI/UX REDESIGN BACKLOG** grouped by:
global design-system issues · screen-specific redesigns · bottom sheets/dialogs ·
navigation/interactions · light/dark theme · Arabic/RTL · accessibility/readability.

Then a single coordinated redesign pass — no fragmented UI edits during QA.

---

## Test log

### Q00-01 — Docker stack health
- 2026-08-26 00:19
- Expected: all Supabase containers up/healthy, Postgres accepting connections.
- Actual: 8 running, 0 unhealthy, 0 restarting, `pg_isready` OK.
- Result: **PASS** (user-confirmed)
- Observation: exclusions understood/accepted; disk note recorded as N-001.
- Finding: none new.

### Q00-02 — Local Supabase reachability
- 2026-08-26 00:21
- Expected: auth/rest/edge reachable on loopback + hotspot LAN; Postgres responsive.
- Actual: 200 on all three, both paths. Authenticated LAN read of `user_transactions` = 57 rows. `select 1` OK. en0=172.20.10.2 matches SUPABASE_LAN_URL.
- Result: **PASS** (user-confirmed)
- Note: an initial 401 on the edge function was a TEST-HARNESS error (missing `Authorization: Bearer`), not a defect. Re-tested = 200.
- Finding: none.

### Q00-03 — Admin Dashboard
- 2026-08-26 00:22
- Expected: dev server up, /login public, all admin routes protected, bound to local Supabase.
- Actual: :3001 listening; /login 200; 9/9 routes 307→/login; NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321; DEMO_LOCAL=true. Page renders with Arabic title and form controls.
- Result: **PASS** (user-confirmed "all good")
- Finding: N-002 (low) CSS compile noise, no visible impact.

### Q00-04 — iPhone hotspot connectivity
- 2026-08-26 00:26
- Expected: Mac + iPhone on the same private hotspot network; app able to reach local backend.
- Actual: en0=172.20.10.2, gateway=172.20.10.1 (iPhone = hotspot host), ARP confirms, device `connected`, 644 Dart requests received incl. live gamification pulls.
- Result: **PASS** (user-confirmed)
- Finding: none. Network posture satisfies DF-007.

### Q00-05 — App running on device
- 2026-08-26 00:26
- Expected: app installed, process alive, talking to local backend, session active.
- Actual: com.youssefsafwat.mali 0.1.3(39); PID 1639; 16 Dart reqs/5min; user_id=702a097d-... (demo user).
- Result: **PASS** (user-confirmed: app on Home screen, no errors)
- Observation: app is past onboarding + login.
- Finding: none.

### Q00-06 — App backend URL
- 2026-08-26 00:27
- Expected: app configured to the local LAN backend only.
- Actual: build defines confirm SUPABASE_LAN_URL=http://172.20.10.2:54321; 0 hosted-supabase refs in kong/auth/rest logs; only reachable Mac address from the phone is .2.
- Result: **PASS** (user-confirmed)
- Method note: proof is topological inference (single possible route), not a Host-header read.
- Finding: none.

### Q00-07 — Zero hosted-Supabase contact
- 2026-08-26 00:29
- Expected: no real network contact with the three protected project refs.
- Actual: 0 established connections; 0 forbidden refs in every container log; 0 in .env.demo/admin/.env.local/config.toml/functions .env; no linked-project.json. Only occurrences are intentional deny-lists (demo_guard.sh, demo_local_capability.dart, bootstrap_runner.dart, admin/lib/demo-guard.ts).
- Result: **PASS** (user-confirmed)
- Self-correction: first probe mis-reported `realtime=2` and an empty config section due to my command phrasing; re-ran explicitly → all zero.
- Finding: none.

### Q00-08 — Demo guard (fail-closed)
- 2026-08-26 00:31
- Expected: guard rejects the 3 protected refs and any non-local target; accepts local only.
- Actual: shell guard rejected production/evidence-staging/validation-staging/unknown-hosted/arbitrary-public; accepted http://172.20.10.2:54321. Admin: demo-guard imported in supabase.ts, supabase-server.ts, middleware.ts. App: bootstrap_runner.dart:337 calls _assertDemoLocalBackend.
- Result: **PASS** (user-confirmed)
- Deferred: D-001 negative runtime tests for Admin/App layers.
- Finding: none.

### Q00-09 — Seeded backend counts
- 2026-08-26 00:35
- Expected: seeded dataset intact and money invariants hold.
- Actual: 11/11 tables exact match; demo.user + demo.admin confirmed; admin_users=1; amount<=0 → 0; bad currency → 0; goal != sum(contributions) → 0.
- Result: **PASS** (user-confirmed)
- Finding: none.

### Q00-10 — Financial PUSH parked
- 2026-08-26 00:35
- Actual: push provider not overridden; production default `unknown`; 0 financial writes; server counts static.
- Result: **PASS** (user-confirmed)

### Q01-01 — Cold launch
- 2026-08-26 00:40
- Expected: app launches from icon after force-close.
- Actual: **FAIL** — SIGSEGV; FlutterEngine cannot be created in debug mode outside Flutter tooling.
- Result: **FAIL** → F-001 (BLOCKER)
- QA frozen at Q01-01 per user instruction. No code changed, no reinstall, no reset.

### Q01-01 — Cold launch (RE-RUN after F-001 remediation)
- 2026-08-26 01:03
- Expected: app opens standalone from the icon, session restores, connects to local backend.
- Actual: **PASS** — user reports app opened, stayed open, went straight to Home.
  Backend: 180 Dart requests; 0 password logins and 0 refresh calls (session restored from local
  storage); 3 catalog-versions cycles; 48 money-pull requests; 0 financial writes; Runner process
  alive; zero Flutter tooling attached.
- Result: **PASS** (user-confirmed)
- Finding: F-001 REMEDIATED_DEMO_ONLY.

### Q01-02 — Login screen
- 2026-08-26 01:05
- Status: **DEFERRED_TO_Q01-10** (see D-002). Not skipped, not passed.
- Reason: authenticated session active; reaching the login screen would require a logout that may
  wipe local Drift and lose the pulled dataset. User chose option A.

### Q01-06 — Authenticated session integrity
- 2026-08-26 01:04
- Expected: session bound to demo user only; no cross-user state; authenticated calls succeed.
- Actual: single user_id (702a097d-...), 0 admin-identity requests, no 401/403. App Settings displays "ليلى الحربي" and demo.user@qirsh.test.
- Result: **PASS** (user-confirmed)
- Observation: 12 active auth sessions on the server — accumulated from my own curl tests and repeated app launches, not user behaviour. Environment-hygiene note only, not a defect.

### Q01-07 — Onboarding state
- 2026-08-26 01:05
- Expected: onboarding recorded server-side and not re-shown.
- Actual: completed_at=2026-08-25 20:48:06 (stable), admin NULL, app goes straight to Home.
- Result: **PASS** (user-confirmed)
- Side finding: F-002 (duplicate user_settings) — now FIXED_DEMO_ONLY.

### Q01-08 — Restart with existing session
- 2026-08-26 01:12
- Expected: opens to Home without login; data intact; merged settings name shown.
- Actual: **PASS** — user confirms Home + "ليلى الحربي". Backend: 75 Dart reqs, 0 password logins,
  1 boot cycle, 24 money pulls, 0 financial writes, user_settings = 1 row (revision 5).
- Result: **PASS** (user-confirmed)
- Finding: N-003 (LOW, revision inflation) recorded, not remediated.

### Phase 1 status
- Q01-01 PASS · Q01-05 (loading state) folded into Q01-01/Q01-08 observations
- Q01-06 PASS · Q01-07 PASS · Q01-08 PASS
- Q01-02 / Q01-03 / Q01-04 / Q01-09 / Q01-10 → **DEFERRED as one auth block (D-003)**

### Q02-01 — Accounts initial pulled state
- 2026-08-26 01:18
- Expected: 4 accounts, seeded order/names/types/currencies, balances 18450.75 / -1240.50 / 365.00 / 712.25, total 18,287.50 SAR.
- Actual: user confirms all four visible, order correct, balances match, total 18,287.50.
- Result: **PASS** (user-confirmed)
- Cross-check: UI == Docker truth, exact to the cent including the negative card balance.
- Finding: N-004 recorded (set_default_account RPC mutation).

### Q02-02 — Transactions initial pulled state
- 2026-08-26 01:22
- Expected: 57 server rows; UI likely 56 if future-dated row is filtered; ordering/merchants/amounts to match; 1 pending.
- Actual: user reports **56** and everything else matching.
- Result: **PASS** (user-confirmed) — app filtering is correct.
- Finding: F-003 (OPEN, seed defect).

### Q02-03 — Controlled mutation → pull → Drift → UI  ★ Phase-2 core proof
- 2026-08-26 01:24
- Pre-state: id `8afc35e0-…`, occurred_at 2026-08-28, amount 16500.00 SAR credit/income,
  revision 1, updated_at 17:16:29.570660Z; server count 57; app showed 56 (row hidden as future).
- Mutation: `occurred_at` only → 2026-08-24. Triggers bumped revision 1→2 and
  updated_at → 22:23:59.157217Z.
- Trigger action: user backgrounded the app ~5s and reopened it (normal resume path — NOT a
  cold start, NOT a demo shortcut, NOT a manual Drift insert).
- **Cursor evidence (decisive):**
  - before → `updated_at.gt.2026-08-25T17:16:29.570660Z … id.gt.fbffb337-…`
  - after  → `updated_at.gt.2026-08-25T22:23:59.157217Z … id.gt.8afc35e0-b4ae-4e99-83b4-8a41ed19…`
  The new cursor is *exactly* the mutated row's updated_at and id — the pull observed the changed
  row and advanced past it.
- Verification:
  - UI count 56 → **57**, salary visible dated 24 Aug (user-confirmed on device)
  - same id still present (1) → **updated, not reinserted**
  - server count still **57**; salary rows still **3**; rows at (16500, 24 Aug) = **1** → no duplicate
  - amount 16500.00 / SAR / credit / income → **unchanged**
  - future-dated rows → **0**
  - client financial writes during the whole test → **0** (push still parked)
  - 2 new transaction pull requests, 59 new Dart requests
- Result: **PASS** (user-confirmed on the physical device)

### Q02-04 — Budgets initial pulled state
- 2026-08-26 01:32
- Expected (corrected): budgets are ACCOUNT-SCOPED to مدى; spend groceries 1644.30 / transport 380.00 / restaurants 355.50.
- Actual (device screenshot): بقالة 1,644 (66%, باقي 856) · مواصلات 380 (42%, باقي 520) · مطاعم 356 (30%, باقي 845). Header: 4,600.00 budgeted, 2,379.80 spent, 52%, 3 budgets.
- Result: **PASS** (user-confirmed, screenshot evidence)
- **My error, corrected:** my first expected figures ignored the budgets' account scoping, so they
  looked like a mismatch. Re-queried with `local_account_id='acc-mada'` → exact match to the cent.
  The app was right; my query was wrong.
- Findings: UX-001 (rounding inconsistency), UX-002 (hardcoded black/white vs theme), UX-003 (budget bottom sheet).

### Q02-05 — Goals + contributions
- 2026-08-26 01:40
- Expected: 2 goals (18,500/50,000 and 4,300/12,000), 5 contributions (6000+6000+6500 / 2000+2300).
- Actual: user confirms both goals with correct figures and 5 contributions.
- Result: **PASS** (user-confirmed)
- Invariant: saved_amount == SUM(contributions) verified on device and in DB.

### Q02-06 — Subscriptions & instalments
- 2026-08-26 01:55
- Expected: 4 items — STC 399.00 (الراجحي, 29 Aug), iPhone instalment 458.25 (الراجحي, 2 Sep, 5/12, تابي, 5499.00), Netflix 56.00 (مدى, 5 Sep), gym 250.00 (مدى, 13 Sep, paused).
- Actual: user confirms all four correct **and the accounts match**.
- Result: **PASS** (user-confirmed)
- Note: the app does surface the owning account per subscription — good, no UX gap here.
- F-004 monitor: default still الراجحي ✅

### Q02-07 — Bill payments
- 2026-08-26 02:00
- Expected: 7 payments / 2,746.25 SAR — 5× iPhone instalment 458.25 (الراجحي, Mar–Jul, idx 1..5), STC 399.00 (الراجحي, 8 Jul), Netflix 56.00 (مدى, 12 Jul).
- Actual: user confirms all seven correct and accounts match.
- Result: **PASS** (user-confirmed)
- F-004 monitor: default still الراجحي ✅ but revision moved **14 → 16** (two further no-op
  re-assertions with no state change) — live confirmation of the F-004 mechanism. Account
  unchanged, so QA continues per the monitoring rule.

### Q02-08 — Plans / planning entities
- 2026-08-26 02:05
- Expected: 2 plans — ميزانية رمضان 6,000.00 SAR active (15 Aug→14 Sep, accounts مدى + الراجحي);
  مصاريف المدرسة 9,500.00 SAR closed (25 Apr→25 Jul, account الراجحي). 0 plan↔transaction links.
- Actual: user reports data correct; **linked accounts NOT shown**; closed plan IS shown;
  page design does not match the app's design system; everything else fine.
- Result: **PASS on data** (user-confirmed) with UX-004 / UX-005 / UX-006 raised.
- Note: `user_plan_transaction_links = 0` is a **seed gap of mine**, not a product issue — the
  seed never linked transactions to plans, so any "spent from plan" figure should read zero.
- F-004 monitor: default still الراجحي ✅

### Q02-09 — Second pull / no duplicates
- 2026-08-26 02:10
- Expected: repeated resume must not duplicate or re-fetch everything.
- Actual: app count stayed **57** (user-confirmed); server 57; **0** duplicate payload ids;
  pull used a **delta cursor** (`updated_at.gt.2026-08-25T22:23:59.157217Z … id.gt.8afc35e0-…`),
  not a full page; **0** financial writes; accounts/budgets/goals unchanged (4/3/2).
- Result: **PASS** (user-confirmed)
- Note: the default-account change seen during this test was the **user's own manual switch** from
  the Accounts screen — not a defect. See the F-004 retraction.

### Q02-10 — Cold-restart persistence
- 2026-08-26 02:20
- Expected: all pulled data present straight from local Drift after a cold start; pull returns an empty delta.
- Actual: user confirms 57 transactions and all accounts/budgets/goals unchanged.
  Backend: 0 password logins, 0 catalog-versions cycles, 1 transaction pull **with delta cursor**,
  0 full-page fetches, 0 financial writes, server still 57/4/3/2.
- Result: **PASS** (user-confirmed)

---

## PHASE 2 — COMPLETE (Financial pull)

| Test | Subject | Result |
|---|---|---|
| Q02-01 | Accounts initial pulled state | PASS |
| Q02-02 | Transactions initial pulled state | PASS |
| Q02-03 | **Controlled mutation → pull → Drift → UI** | **PASS ★** |
| Q02-04 | Budgets | PASS |
| Q02-05 | Goals + contributions | PASS |
| Q02-06 | Subscriptions & instalments | PASS |
| Q02-07 | Bill payments | PASS |
| Q02-08 | Plans | PASS (data) + UX-004/005/006 |
| Q02-09 | Second pull / no duplicates | PASS |
| Q02-10 | Cold-restart persistence | PASS |

**Financial PUSH stayed parked throughout: 0 client monetary writes across the entire phase.**
Every financial family was visually confirmed on the physical device against Docker truth.

### Q03-01 — Home total balance
- 2026-08-26 02:25
- **What Home actually shows:** «إجمالي المصروفات» — **net expenses**, i.e. `debits − refunds`,
  scoped by the selected account **and** the date-range filter. It does **not** show a balance.
- Reconciliation (الراجحي):
  - هذا الشهر → debits 2,319.00 − refund 199.00 = **2,120.00** = app value ✅
  - هذا الأسبوع → **0.00** (no rajhi debits this week); only the 16,500.00 salary credit appears
    in آخر العمليات ✅
- Result: **PASS** (screenshot evidence)
- **Two errors of mine, corrected by the user's screenshots:**
  1. I predicted Home would show a *balance* from `latestBalanceAfter` — it shows net expenses.
     I read the provider code too quickly and built the whole expectation on it.
  2. I did not anticipate refunds being netted off, so I tried 11 different scopings before
     reaching the right formula.
  `balance_after` **is** surfaced by the app — in the transaction detail sheet as «الرصيد بعد»
  (SAR 18,450.75 on the salary row), not on Home.
- Related: the mutated Q02-03 salary row displays correctly at **24 أغسطس** in the detail sheet,
  independently re-confirming the pull chain.
- Observation (not a defect): «متاح من ميزانية الشهر» prompts «حدّد ميزانية شهرية» even though 3
  budgets exist — because all three are **category budgets scoped to مدى**, not a general
  `all_expenses` monthly budget. Correct behaviour; may look odd in a demo.

### Q03-02 — Home account selector / per-account totals
- 2026-08-26 02:28
- **Complete formula established:** `إجمالي المصروفات = confirmed debits − refunds`, scoped by
  **selected account + date range**. Pending transactions are excluded until reviewed.
- Reconciliation:
  | account | debits | pending | refunds | net expected | app |
  |---|---|---|---|---|---|
  | الراجحي · month | 2,319.00 | 0 | 199.00 | 2,120.00 | 2,120.00 ✅ |
  | مدى · month | 2,881.05 | 145.00 | 0 | 2,736.05 | 2,736.05 ✅ |
- Also correct: «1 عملية في انتظار مراجعتك» banner appears (the 145.00 pending row), and
  «متاح من ميزانية الشهر 41%» appears only for مدى — because all three budgets belong to مدى.
  4,600 − 2,736.05 = 1,863.95 → 40.5% ≈ 41% ✅. The «حدّد ميزانية» prompt on الراجحي was correct,
  not a defect.
- Result: **PASS** (screenshot evidence)
- **My error again:** I predicted 2,881.05 because I forgot pending transactions are excluded.
  The app was right.
- Finding: UX-007 (selector does not name the active account).

### Q03-03 — Home recent transactions
- 2026-08-26 02:34
- Expected (مدى · هذا الشهر, newest first): بنده 287.40 · [غير معروف 145.00 pending] · أرامكو 95.00 ·
  تميمي 164.90 · مطعم النخيل 118.50 · بنده 287.40 · Amazon.ae 356.25 · أرامكو 95.00 · تميمي 164.90
- Actual: identical order and values, **with the pending row omitted**.
- Result: **PASS** (screenshot evidence)
- **Behaviour clarified:** a `pending` transaction is excluded from the total **and** from the
  recent-transactions list. It is reachable only via the «1 عملية في انتظار مراجعتك» banner.
  Recorded as an observation, not a defect — but worth a product decision: a user who taps that
  banner's count and then scans the list will not find the row there.
- Findings: UX-008 (app logo in header — user request), UX-009 (nav bar overlaps content).
- **Seed realism note (mine, not a product issue):** every seeded transaction renders at the same
  clock time **20:16**, because the seed uses `now() - interval 'N days'`, which preserves the
  time-of-day. Fine functionally, slightly unrealistic on screen for a client demo.

### Q03-04 — Home budget / subscriptions / plans sections
- 2026-08-26 02:38
- Budgets on Home: مواصلات 900.00/380.00 42% · مطاعم 1,200.00/355.50 30% · بقالة 2,500.00/1,644.30 66%
  — values all correct, but **all three shown** → F-005.
- Subscriptions on Home: **Netflix 56.00, بعد 10 يوم** only. Correct: scoped to the active account
  (مدى) and active status, so the paused gym is excluded ✅
- Plans on Home: **ميزانية رمضان 20%, المصروف 1,205.45, تنتهي 14 سبتمبر** — verified:
  1,404.45 confirmed debits (مدى+الراجحي, from 15 Aug) − 199.00 refund = **1,205.45** ✅,
  1,205.45/6,000 = 20.1% ≈ 20% ✅. Closed plan correctly absent from Home.
  **Note:** plan spend is derived from in-range transactions on the plan's accounts, NOT from
  `user_plan_transaction_links` (which is empty) — so my earlier "spent should read zero"
  expectation was wrong.
- Result: **PASS on values** (screenshot evidence) · F-005 raised

---

## CLIENT REQUESTS — Home screen (recorded 2026-08-26)

### CR-001 — Client's requested Home section order
1. اليومية · 2. الكوبونات · 3. الشهرية · 4. آخر العمليات ·
5. الاشتراكات (نتفليكس وغيره، تابي، تمارا…) · 6. الأهداف والخطط · 7. برامج السفر والقطة
Current Home order differs. To be reconciled during the redesign pass.

### CR-002 — Reference app «وفير / wafeer» (visual reference only)
The client shared wafeer screenshots as a liked reference. **We implement these patterns in
Qirsh's own design language — not a copy of their look.** Patterns worth taking:
- centred brand logo in the header, with search / notifications / help affordances
- a monthly-budget card: total + progress bar + per-category rows carrying an icon,
  operation count, remaining amount, and an inline «تعديل» action
- «آخر 5 عمليات» with merchant logos, category chips and quick inline actions
- prominent «+» FAB in the bottom navigation
- an explicit «اضافة ميزانية جديدة» call to action inside the budget card

### Q03-05 — Home goals summary
- 2026-08-26 02:48
- Hypothesis tested: are goals account-scoped like the other Home sections?
- **Answer: YES.** With مدى selected the «الأهداف» section is entirely absent (both goals belong to
  الراجحي). Switching to الراجحي makes it appear:
  صندوق الطوارئ **37%** · تم توفير **18,500.00** · باقي **31,500.00** ✅ (50,000 − 18,500 = 31,500)
- Also verified in the same view: STC — ألياف 399.00 «بعد 3 يوم» ✅ (due 29 Aug, today 26 Aug);
  rajhi transactions نون +199.00 / نون −1,899.00 / مستشفى −420.00 ✅
- Result: **PASS** (screenshot evidence). Home scoping is fully consistent across budgets,
  subscriptions, goals and plans.
- **Design pattern noted (intentional, not a defect):** each Home section shows a **single preview
  item** plus a «الكل» link — رحلة إسطنبول and the iPhone instalment are correctly not shown.
- Finding: UX-010 (sections vanish silently when empty for the selected account).

### Q03-06 — Home monthly / today summary
- 2026-08-26 02:50
- Actual (الراجحي · هذا الشهر): إجمالي المصروفات 2,120.00 ✅ · دخل اليوم 0.00 · مصروف اليوم 0.00 ·
  الصافي 0.00 ✅ (no transactions today, latest is 24 Aug) · «حدّد ميزانية شهرية» correctly shown.
- Comparison badge investigated: it **is** week-over-week, matching its label.
  Proof (مدى): this week 382.40 vs previous week 1,022.05 → −62.6% ≈ **−63%** as displayed ✅
- Result: **PASS on values** (screenshot evidence) · **F-006 raised** (0 vs 0 → −100%)
- **Correction:** I predicted the «عن الأسبوع الماضي» label would prove misleading because the
  filter said «هذا الشهر». It is not — the badge is genuinely weekly. Withdrawn.

### Q03-07 — Home empty / low-data states
- 2026-08-26 02:53
- Actual (نقداً · هذا الشهر): إجمالي المصروفات **60.00** ✅ (single transaction سوق الخضار 60.00−);
  دخل/مصروف اليوم 0.00 ✅; «حدّد ميزانية شهرية» ✅; الميزانية/الاشتراكات/الأهداف all correctly absent.
- Result: **PASS on values** (screenshot evidence) · **F-006 reconfirmed** · **F-007 raised**
- This low-data test proved far more valuable than the populated cases — both new defects came
  from it.

### Q03-08 — Home loading / refresh behaviour
- 2026-08-26 02:58
- **Loading:** user confirms data appears **immediately**, no skeleton/loading flash — Drift serves
  the UI before any network work. Visual confirmation of what Q02-10 proved technically.
- **Refresh:** backend shows 5 transaction pulls in the window, **all delta-cursor**, **0 full-page**
  fetches, **0** financial writes, server data unchanged (57/4/3).
- **No pull-to-refresh gesture exists** → UX-011.
- Result: **PASS** (user-confirmed)

### Q03-09 — Home navigation
- 2026-08-26 03:00
- Actual: **all buttons open the correct screens** (5 bottom-nav tabs, «الكل» links on each section,
  «إدارة» on Budgets, «+» add action). Routing verified by the user.
- Result: **PASS on function** (user-confirmed) · **UX-012 raised** (icons not legible)
- Nothing was saved from the «+» sheet; no data mutated; PUSH still parked.

---

## PHASE 3 — COMPLETE (Home)

| Test | Subject | Result |
|---|---|---|
| Q03-01 | Home total (net expenses) | PASS |
| Q03-02 | Account selector / per-account totals | PASS |
| Q03-03 | Recent transactions | PASS |
| Q03-04 | Budget / subscriptions / plans sections | PASS + F-005 |
| Q03-05 | Goals summary | PASS |
| Q03-06 | Monthly / today summary | PASS + F-006 |
| Q03-07 | Empty / low-data states | PASS + F-006 reconfirmed + F-007 |
| Q03-08 | Loading / refresh | PASS + UX-011 |
| Q03-09 | Navigation | PASS + UX-012 |

**Home formula established and verified across four accounts:**
`إجمالي المصروفات = confirmed debits − refunds`, scoped by selected account + date range.
Every displayed figure reconciled to Docker truth to the cent.

### Q04-01 — Accounts list (read-only)
- 2026-08-26 03:05
- Actual: 4 seeded accounts all present with correct names/types/currencies; مدى badged «افتراضي» ✅;
  distinct per-account icons; «إضافة حساب» CTA present.
- Result: **PASS on data** (screenshot evidence)
- Findings: **UX-013** (no balances displayed), **F-008** (extra local-only account «الحساب الرئيسي»).
- Note: my planned check of how a **negative** balance renders could not be performed — no balances
  are shown anywhere on this screen.

### Q04-08 — Account with many transactions  ⚠️ **CORRECTED**
- 2026-08-26 03:19
- **First recorded as PASS in error.** I logged PASS on the user's initial "all 34 are showing"
  before asking them to actually count. When the user counted, the screen showed **20**, and the
  pending «غير معروف» 145.00 row was **not** present. My mistake: I accepted a summary answer for a
  test whose entire point was the count.
- Corrected result: **FAIL** → **F-009** (hard `limit: 20`, 14 rows unreachable).
- Scrolling itself was smooth ✅
- **A prediction of mine was also wrong:** I expected the pending row to appear here but not on
  Home, i.e. a cross-screen inconsistency. It does **not** appear here either — behaviour is
  consistent across both screens. Withdrawn.
  (Caveat: with the 20-row cap I cannot fully separate "explicitly excluded" from "outside the
  first 20" — though the pending row is dated 24 Aug, among the newest, so explicit exclusion is
  the likely explanation.)

### Q04-02 — Account detail (read-only)
- 2026-08-26 03:09
- الراجحي: card فيزا السفر ****9032 VISA ✅ · 6 transactions (16,500+ · 199+ · 1,899− · 420− ·
  16,500+ · 16,500+) ✅ — matches Docker count and amounts exactly.
- مدى: card مدى الرئيسية ****4417 ✅ · «افتراضي» badge ✅ · بنده 287.40− · أرامكو 95.00− ·
  تميمي 164.90− · النخيل 118.50− · بنده 287.40− · Amazon.ae 356.25− ✅
- Result: **PASS on data** (screenshot evidence)
- Findings: **UX-013 escalated to HIGH**, UX-014 (title truncation), UX-015 («يدوية» jargon)
- **Two planned checks were impossible:** negative-balance presentation and unset-credit-limit
  presentation — neither value is rendered anywhere in the app.

### Q04-10 — Accounts persistence after cold restart
- 2026-08-26 03:22
- Actual: user confirms all data identical after a full App-Switcher kill + relaunch; مدى still
  default, card ****4417 present, transaction count still **20** (the F-009 cap, reproducible).
- Result: **PASS** (user-confirmed)

---

## PHASE 4 — READ-ONLY PORTION COMPLETE (Accounts)

| Test | Subject | Result |
|---|---|---|
| Q04-01 | Accounts list | PASS + UX-013 + F-008 |
| Q04-02 | Account detail | PASS + UX-013↑HIGH + UX-014/015 |
| Q04-03 | Create account | **DEFERRED → Phase 6** |
| Q04-04 | Edit account | **DEFERRED → Phase 6** |
| Q04-05 | Exact money | covered by Q02-01 / Q03-01…07 across 4 accounts |
| Q04-06 | Currency behaviour | covered — all accounts SAR, currency shown correctly everywhere |
| Q04-07 | Delete / archive | **DEFERRED → Phase 6** |
| Q04-08 | Account with many transactions | **FAIL → F-009** (20-row cap) |
| Q04-09 | Invalid input | **DEFERRED → Phase 6** (needs the form) |
| Q04-10 | Persistence | PASS |

### Q05-01 — Transactions list
- 2026-08-26 03:23
- Filters in effect: account **مدى**, range **آخر 90 يوم**.
- Header reconciliation: **34 عملية للفترة** (= all of مدى's transactions) · **1 قيد المراجعة** ·
  **إجمالي المصروف 5,682.65** = 5,827.65 debits − 145.00 pending ✅ — count includes the pending
  row, the total excludes it, and it is reported separately. Sound accounting design.
- User scrolled to the end: list terminates at **2 July** → all 34 rendered, **no cap**.
- **Pending row IS visible here**, badged «قيد المراجعة», categorised «غير مصنّفة».
- Screen also provides: account + date-range selectors, العمليات/الفواتير tabs, free-text search
  («ابحث باسم متجر، تصنيف، مبلغ أو عملة»), and type chips (الكل/مصروفات/دخل/تحويلات/التصنيف).
- Result: **PASS** (screenshot + user confirmation)
- **Withdrawn concern of mine:** I had worried the pending transaction was effectively invisible in
  the app. It is not — it is deliberately hidden from summary surfaces and shown, badged, on the
  dedicated screen. That is coherent design, not a defect.
- Findings: **UX-016** (no pending filter); the black «العمليات» tab and «الكل» chip are further
  instances of **UX-002**.

### Q05-02 / Q05-03 — Filters and search
- 2026-08-26 03:30
- User exercised the type chips (مصروفات / دخل / تحويلات) and free-text search (merchant, amount,
  category) and reported **«كله تمام»**.
- Result: **PASS (user-attested)** — ⚠️ **not independently verified.** I requested six specific
  counts (chip counts and search-result counts) to reconcile against Docker; the user opted to
  move on. Recorded honestly as attested rather than reconciled.
- **Not covered, and worth revisiting if time allows:**
  - the **empty-filter state** for «دخل» / «تحويلات» on مدى (both are 0 rows) — empty states have
    produced 3 of our 5 product findings so far;
  - whether **search by amount** («287.40») actually works, since the placeholder promises
    «مبلغ أو عملة».
- Expected values, for whoever re-runs this: الكل 34 / مصروفات 34 / دخل 0 / تحويلات 0;
  «بنده» → 7, «287.40» → 7, «بقالة» → 14.

### Q05-04 — Transaction detail (foreign currency)
- 2026-08-26 03:30
- Chose Amazon.ae deliberately — the only row carrying a foreign currency.
- All fields reconcile: 356.25 ريال (red = expense) · **بالعملة الأصلية AED 349.00** · تسوق · شراء ·
  بنك · ريال · «طلب دولي» · مؤكدة · الأحد 16 أغسطس 2026 20:16 ✅
- **Three risk cases I flagged in advance, all handled correctly:**
  1. **Foreign currency is displayed**, labelled «بالعملة الأصلية» — accurate wording (the original
     currency of the purchase, not a derived FX rate).
  2. **Null `balance_after` → the row is omitted entirely**, not rendered as `0.00`. This is the
     correct choice: zero ≠ unknown. Contrast with the salary row, where `balance_after` exists and
     the «الرصيد بعد» row does appear.
  3. **Parser confidence 0.88 is not exposed** to the user — internal data kept internal.
- «النص الأصلي» is available as an expandable section, so the originating SMS is retained and
  auditable — good transparency.
- Minor: «المصدر: بنك» is a deliberate user-facing translation of `android_sms` — correct, not a defect.
- Result: **PASS** (screenshot evidence)

### Q05-09 / Q05-10 — Income vs expense classification
- 2026-08-26 03:32
- Setup: الراجحي · آخر 90 يوم · «دخل» chip.
- Predicted two outcomes: **3 rows** (refund correctly excluded) or **4 rows** (refund treated as
  income → double counting).
- **Actual: 4 rows** — 16,500.00+ (24 Aug), **نون 199.00+ (19 Aug)**, 16,500.00+ (28 Jul),
  16,500.00+ (28 Jun).
- Result: **FAIL → F-010**

### Q05-11 — Transfers excluded from income/expense
- **NOT_TESTABLE** — the seed contains **zero** `transfer` rows
  (expense 52 · income 3 · refund 1 · unknown 1 · **transfer 0**).
- Deferred to **Phase 6**, where a real transfer will be created and the full chain verified.
  Adding a transfer to the seed is possible but is a data change requiring user approval.

### Q17-01 — Admin login and dashboard
- 2026-08-26 03:40
- Login as `demo.admin@qirsh.test` succeeded and routed to `/dashboard` — first successful
  **positive** auth test for the Admin (Q00-08 only proved the negative case, i.e. route protection).
- Figures confirmed matching Docker: users 2 · banks 136 · parsers 12 · categories 21 ·
  feature flags 26 (3 active) · announcements 0.
- Result: **PASS** (user-confirmed)
- Note: admin membership is enforced via `admin_users` (1 row), read with the user's own session;
  page data is then read with `service_role` server-side behind `requireAdmin()`.

### Q17-02 — Admin: Banks
- 2026-08-26 03:44
- Actual: **136 من 136** rows rendered with an explicit count · all «مفعّل» · EG rows first
  (Docker: EG = 36 of 136) · short codes and `sms_senders` chips correct, with a «1+» overflow
  indicator.
- Features observed: search across bank name / code / **sender id**; country and status filters;
  an in-UI explainer banner describing what «أرقام المُرسل» are and that a missing sender id
  prevents the app from recognising that bank's messages — good embedded documentation.
- Result: **PASS** (user-confirmed «all good», screenshot evidence)
- **Notable:** bank logos (`logo_url`) are **not rendered** in the table — text only. My concern
  about broken remote images in an isolated environment therefore does not apply. Possible
  enhancement: show the logo to aid scanning across 136 rows.

---

## D-003 — AUTH/LOGOUT/LOGIN BLOCK · **DEFERRED** (re-affirmed 2026-08-26 04:30)

Status: **DEFERRED — not PASS, not FAIL.** Covers Q01-02, Q01-03, Q01-04, Q01-09, Q01-10.

User decision: defer until after the financial write/push phase and until preserving
the current Drift state is no longer required. No logout attempted.

### Why it was re-deferred

Sign-out is destructive and irreversible in a way that would forfeit the Phase-6
prerequisite the user set ("inventory every currently pending local financial row
... before enabling PUSH"). `AppSession.signOut()` (`app_session.dart:442`) runs, in
order: invalidate owner generation → `flushPendingForSignOut()` (a push) → full local
financial wipe. `app_shell.dart:575` shows that flush drives five push services,
including `ledgerPushService.push()`.

### Evidence recorded — established WITHOUT touching device state

**1. Exact financial create/update writes are CONFIRMED PARKED.**

`shouldParkExactMoneyWrite` requires `cutoverState == canonical && pushCapability != verifiedExact`.
Both operands were established by source reading, via two independent paths:

- *Runtime value:* `planningCutoverCoordinatorProvider` (`app_providers.dart:115`)
  builds `DbBackedPlanningCutoverCoordinator(initialState: canonical, …)`. `state()`
  returns `_state`, mutated only by `refreshFromDatabase()`, whose sole non-test call
  site is `planning_currency_repair_providers.dart:132` — the currency-repair flow,
  never invoked this session. State therefore remains `canonical`.
- *DB-derived value:* would also be `canonical` — `_targetSchemaVersion = 31` (≥ 30),
  the migration at `app_database.dart:1911` sets `planning_cutover_state = 1`, and a
  violation count > 0 raises rather than downgrading.
- *Push capability:* `unknown`. `demo_local_capability.dart` deliberately omits
  `exactPushTransportCapabilityProvider`; the production default is `unknown`.

→ money-bearing writes are parked **before any network send**
(`ledger_push_service.dart:175`). §14 honesty constraint holds.

**2. DELETE bypass is CONFIRMED BY SOURCE; no pending delete is proven.**

The parking precondition is explicitly `item.operation != OutboxOperation.delete`, so
a pending financial DELETE would be transmitted during a sign-out flush. Whether any
such row exists is **unknown**. Circumstantial only: all write tests are deferred, no
delete was performed during QA, and the server still matches at 57 transactions /
4 accounts.

**3. Current pending-local inventory is UNKNOWN — Drift is encrypted.**

The app data container was copied read-only (`xcrun devicectl device copy from`,
1,114,112 bytes; a device read, not a mutation). Header bytes are
`5821 e492 9815 af68 …`, not `SQLite format 3\0` — the file is SQLCipher-encrypted.
The key lives in the iOS Keychain (`database_key_store.dart`); enumerating all 60
container files found no key material. The file is unreadable.

Still unknown: `ledger_sync_outbox` / `planning_sync_outbox` contents (rows, operation,
parked vs pending), `unprovenFinancialRows`, `unresolvedConflicts`, `localOnlyCards`,
`smartInboxPending`, and whether any financial DELETE is queued.

**4. «الحساب الرئيسي» identified.** Not a stale fixture — it is the app's
auto-seeded default account, `kDefaultAccountLocalId = 'default_account'`
(`app_database.dart:92`), created only when the accounts table is empty and
**deliberately reseeded after every sign-out**. The server holds no account with that
`local_id` (its four are `acc-rajhi`, `acc-mada`, `acc-stcpay`, `acc-cash`), so if it
exists locally it belongs to the `unprovenFinancialRows` class.

**5. No logout, wipe, flush, ack, park/unpark, Drift mutation, or Docker mutation
occurred.** Push remains parked. Server baseline unchanged: 57 transactions,
4 accounts, 3 budgets, 2 goals, 1 settings row.

### Demo inventory probe — designed, NOT built

A read-only `DEMO_LOCAL`-gated probe would resolve the unknowns by calling the
existing `UnsyncedInventoryService.collect()` plus detail `SELECT`s, writing JSON to
`Documents/` for retrieval by the same read-only `devicectl copy from`.

**Not built.** It requires a rebuild, and free disk is **5.03 GiB** against the
`START_MIN_GIB = 8` floor in `tools/demo_build_profile.sh` — the script would refuse.
User instruction: do not build at current disk levels.

### Revisit only when

- the Phase-6 push inventory is complete, **or**
- the current device state is intentionally ended/reset.

---

## Phase 17 — Admin Dashboard: COMPLETE

- **Q17-03** Parsers page — 12 parsers, all `passed`, all active; priorities 100→60 match. Explicit count «12 من 12» (2nd F-009 precedent). Truncated sender patterns carry a `title` tooltip — not a defect. Findings: **F-011** (validation badge is a migration backfill; `golden_test_count = 0`, `validated_by` NULL, `parser_golden_tests` empty with no Admin code path), **F-012** (12 of 136 banks covered), **F-013** (raised, later retracted). UX-016 (quality counters absent from the list), UX-017 (`message_pattern` not shown). **PASS**
- **Q17-04** Parser Lab — page works; the single-source-of-truth compile step (`dart compile js` of the real engine) is the right design. **F-014 (HIGH)**: the stated device-parity fails three ways — hardcoded `BankProfiles.all` (31) vs the synced catalog (12), a stale June artifact behind 7 engine commits, and no AI fallback. **PASS**
- **Q17-05** Categories — 21/21, flat, all active, colours rendered, keys copyable, no edit/delete affordance (correct for `is_system`). 3rd F-009 precedent. **This page is the model for an F-016 option-B fix.** UX-018 (`all_expenses` sentinel shown as a real category; the app filters it out in two places), UX-019 (banner attributes key dependency to `sms_parsers`, which has no category column; real dependents are `user_transactions`/`user_budgets`/`merchant_keywords`, all TEXT with no FK). **PASS**
- **Q17-06** Referrals — all six referral tables empty, page renders 0 correctly, audit-log empty state good, deactivate button correctly `disabled={busy || !active}`. **Highest-quality page in the product:** `operation_id` intent reuse (fixes prior audit H-13), `outcomeKnown()` distinguishing failure from unknown outcome, consequence-explaining confirmations, reason enforced client-side *and* by `referral_admin_require_reason` (≥4 chars, control-char filter), documented service-role chain. **PASS**
- **Q17-07** Coupons — 0 coupons / 0 coupon categories. **My prediction of "2 coupons" was wrong**; the seed never inserted any. **UX-019 narrowed**: `display_category_key` FKs to `coupon_categories`, not expense categories, and `spend_hint_category_keys` is intentionally FK-free (documented in `0081_coupons.sql:123`). Good empty state; strong anti-misuse banner on interaction metrics; `RESTRICT` FK documented. UX-020 (a «0 من 0» counter reads as breakage). **PASS**
- **Q17-08 / Q17-09** Announcements + Campaigns — both 0, both with good empty states. **F-017 (HIGH)**: `force_update` publishes on one click with no confirmation, reason, idempotency key or audit row, while *deleting* a draft is confirmed. `referral_admin_audit` is the only audit table in the schema. **PASS**
- **Q17-10** Feature Settings — 26 flags, 3 active; both numbers correct. **F-018**: the three active flags (`parser_engine_version`, `enable_announcements`, `enable_goals`) are read by no code, and the three the app does read (`enable_coupons`, `enable_report_ads`, `enable_referrals`) are all off — so no flag currently changes behaviour. MALI-034 is documented in `feature_flag_service.dart:34`; the fail-safe design is sound, the Admin was simply never updated. UX-021 (raw English phase notes shown to a business operator). **PASS**

### Phase 17 conclusion
The two most dangerous surfaces are the two weakest: Parsers (F-016, dead fields) and
Announcements (F-017, missing guards). Everything content-facing is mature. The
remediation pattern already exists in-repo — `referrals/page.tsx`.

---

## Phase 18 — read-only app screens

- **Q18-01 (withdrawn)** Smart Inbox — **not runnable.** There is no Smart Inbox screen; it is a
  banner on the Transactions screen (`transactions_screen.dart:174`) that renders only when
  `smartInboxItemsProvider` is non-empty, and that provider calls `getOpen()`
  (`status='open' AND dismissed_locally=0`). All five seeded rows are `resolved`/`dismissed`, so
  the banner never appears and there is no archive or filter to reach them. **Demo-data gap, not a
  product defect** — my test choice was wrong. Minor observation only: dismissed items have no
  archive path in the UI (retained in Drift and on the server).
- **Q18-01 (replacement)** Reports — user reports "all good" against the Docker expectations for
  مدى / هذا الشهر: بقالة 1,644.30 (7) · مواصلات 380.00 (4) · تسوق 356.25 (1) · مطاعم 355.50 (3),
  total 2,736.05 (15) — matching the Home figure from Q03-02 exactly, i.e. one calculation source.
  **PASS (user-attested, not itemised).** The الراجحي F-010 discriminator was not read back
  separately; see the open question below.

---

## F-010 — NARROWED (2026-08-26) · **OPEN** · no remediation performed

**Scope:** Transactions screen → **Income filter only.**

**Root cause** — `app/lib/data/repositories/drift_transaction_repository.dart:657`:

```dart
case TransactionPageKind.expenses:
  where.add("t.type IN ('payment', 'withdrawal')");   // correct — refund excluded
case TransactionPageKind.income:
  where.add("t.type IN ('income', 'refund')");        // ← DEFECT
case TransactionPageKind.transfers:
  where.add("t.type = 'transfer'");
```

`TransactionPageKind.income` uses a hand-written SQL condition that adds `refund`, instead of the
central semantic in `app/lib/domain/finance/financial_semantics.dart:211`:

```dart
static String incomeTypePredicate({String alias = ''}) => "${p}type = 'income'";
```

`incomeTypePredicate` has **no consumer anywhere in `app/lib` outside its own file** — the correct
predicate exists and is unused, while the screen wrote its own.

**Verified correct surfaces** (no change needed):

| surface | refund treatment | verified |
|---|---|---|
| Home total | subtracted from expenses | Q03-01 — **2,120.00** |
| Reports total | subtracted from expenses | Q18-01 — **2,120.00** (user-confirmed 2026-08-26) |
| Transactions «مصروفات» filter | excluded | `IN ('payment','withdrawal')` |
| Transactions «دخل» filter | **counted as income** | Q05-09/10 — 4 rows instead of 3 |

The refund is therefore double-beneficial **only** on the Income transaction list/summary surface:
expenses fall by 199 *and* income rises by 199 — a 398 swing from a 199 event. The netting
mathematics elsewhere is correct and centrally documented.

**Preferred remediation (later):** consume the central financial-semantics predicate rather than
writing another hand-authored SQL condition. Fixing only the string would leave the same class of
drift available to the next surface.

**Status: OPEN.** Not remediated — guided QA baseline must not change until the sweep completes.
