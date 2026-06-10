# CODEX HANDOFF — money_companion

> دليل التسليم الكامل لـ Codex (أو أي coding agent) لإكمال بناء التطبيق.
> **اقرأ هذا الملف بالكامل قبل أي كود.** المرجعيات التفصيلية: `PRODUCT_SPEC.md` · `SAUDI_MARKET_SPEC.md` · `AUTH_AND_ADMIN_SPEC.md` · `DESIGN_SYSTEM.md` · `WIREFRAMES.md` · `BUILD_PLAN.md` · النموذج: `prototype/onboarding-vibrant.html`.
> المشروع في مجلد `app/`. **الأساس + المحرك + اختباراته منجزة** (Sprint 0 + 1).

---

## 1. Project Overview
تطبيق موبايل عربي (Arabic-first / RTL) يحوّل رسائل البنك والمحافظ الإلكترونية إلى سجل مصاريف مصنّف **تلقائياً** بأقل مجهود. القيمة: «لا تكتب مصروفاتك — نحن نفهمها لك». التجربة مبنية على التلعيب (Streak / XP / مستويات / شارات / **خزنة 2D** / أهداف ادخار) ليصبح التوفير عادة يومية ممتعة.

- **السوق الأول:** السعودية (SAR). تعدد لهجات رسائل بنكية.
- **التمايز:** عمق التلعيب + الخصوصية (on-device) + تصميم سعودي premium. (المنافس المباشر SAY — انظر `COMPETITIVE_ANALYSIS.md`.)
- **North Star:** عدد العمليات الملتقطة والمؤكَّدة أسبوعياً لكل مستخدم نشط.

---

## 2. Non-Negotiable Product Rules (قرارات محسومة — لا تغيّرها)
1. **Login موجود في MVP** (Google + Apple + Email/OTP) أثناء onboarding — هوية من اليوم الأول.
2. **Backup مشفّر اختياري من Settings** — **مطفأ افتراضياً**، وليس إجبارياً في onboarding.
3. **Financial data local by default** — البيانات المالية على الجهاز افتراضياً.
4. **إذا فُعّل الـ backup:** يُرفع **blob مشفّر E2E فقط** — السيرفر لا يملك المفتاح ولا يقرأ المحتوى.
5. **لا توجد مزامنة realtime في MVP** — الاستعادة عند الدخول على جهاز جديد فقط (إن وُجدت نسخة).
6. **لا إعلانات في MVP إطلاقاً.**
7. **ممنوع Interstitial Ads / app-open / auto-play video** نهائياً (حتى في Phase 2).
8. **المحرك (`lib/engine/**`) لا يستورد UI** ولا `package:flutter`.
9. **الـ UI لا يستورد الـ parser مباشرة** — كل شيء عبر usecases/repositories.
10. **بدون إيموجي** — أيقونات Lucide فقط، مع accessibility labels.
11. التزام حرفي بـ `DESIGN_SYSTEM.md` (Vibrant Fintech) وقواعد العمل `PRODUCT_SPEC.md §24/§25`.
12. لا رفع بيانات مالية قابلة للقراءة لأي سيرفر — أبداً.

> أي تعارض بين طلب جديد وهذه القواعد → **توقّف واسأل**، لا تغيّر القرار.

---

## 3. Current Stack
- **Flutter** (>=3.22) + Dart (>=3.4).
- **State:** flutter_riverpod. **Routing:** go_router.
- **Fonts:** google_fonts → **IBM Plex Sans Arabic**. **Icons:** lucide_icons.
- **i18n:** flutter_localizations + intl (ar افتراضي، RTL).
- **قادم (Sprint 2+):** drift + sqlite3_flutter_libs + **sqlcipher_flutter_libs** · flutter_secure_storage · another_telephony (Android SMS) · google_sign_in · sign_in_with_apple · dio · flutter_local_notifications + timezone · rive · cryptography (AES-GCM/Argon2) · freezed/json_serializable/build_runner · mocktail.

---

## 4. Folder Structure
```
app/lib/
  core/
    theme/      # AppColors(ThemeExtension) · AppTypography · AppSpacing/Radius · AppTheme · themeModeProvider
    router/     # go_router
    constants/ utils/ di/        # (تُنشأ عند الحاجة)
  engine/       # ★ Dart نقي — لا flutter
    models/         # ParsedTransaction · TransactionType · TransactionSource
    parser/         # Normalizer · BankProfile(s) · ParseResult · ParserEngine
    categorization/ # Category(ies) · CategorySeeds · MerchantCategoryMap · Categorizer
  data/         # (Sprint 2) db (drift+sqlcipher) · repositories impl · remote clients
  domain/       # (Sprint 2) entities · repository interfaces · usecases
  features/     # شاشات لكل ميزة (onboarding, auth, dashboard, …) — حالياً foundation/ مؤقتة
  l10n/         # (لاحقاً)
app/test/
  engine/       # ★ unit/golden tests للمحرك (منجزة)
```
**قاعدة الطبقات الصارمة:** `features/*` و`data/*` لا يستوردان `engine/parser` مباشرة → عبر usecases/repositories. والمحرك لا يعرف بوجود الواجهة أو DB.

---

## 5. Current Implemented Foundation (منجز — لا تعِد بناءه)
- ✅ `main.dart` + `app.dart`: ProviderScope · MaterialApp.router · RTL (locale ar) · الثيمين.
- ✅ `core/theme/*`: كل tokens الـ Design System (Light/Dark) + Typography (IBM Plex Sans Arabic، tabular figures للمبالغ) + Spacing/Radius.
- ✅ `core/router/app_router.dart`: go_router بمسار `/` مؤقت.
- ✅ `engine/parser/*`: Normalizer (أرقام هندية→غربية، توحيد SAR، تطويل/مسافات) + ParserEngine (amount/merchant/type/source/last4/date/balance/confidence + تجاهل غير المالي) + BankProfiles (snb/alrajhi/riyad/stcpay).
- ✅ `engine/categorization/*`: 20 تصنيف + بذور سعودية + MerchantCategoryMap (تعلّم) + Categorizer.
- ✅ `test/engine/*`: normalizer + parser (11 حالة) + categorizer. **يجب أن تبقى خضراء دائماً.**
- 🟡 `features/foundation/foundation_home_screen.dart`: smoke test مؤقت — **استبدله** عند بناء onboarding/dashboard.

---

## 6. Engine Rules
- **Dart نقي بالكامل** — `import 'package:flutter/...'` ممنوع داخل `lib/engine/`.
- مدخلات/مخرجات عبر DTOs (`ParsedTransaction`, `ParseResult`, `CategoryResult`).
- لا تخزين ولا I/O داخل المحرك — منطق خالص قابل للاختبار.
- قابل للتوسعة: إضافة بنك = إضافة `BankProfile` + قواعد، دون لمس الواجهة.
- كل تغيير في المحرك يأتي مع golden tests.

---

## 7. Parser Rules
- **التطبيع أولاً:** أرقام هندية/فارسية → غربية، توحيد العملة (`ريال`/`ر.س`/`﷼` → `SAR`)، إزالة تطويل، توحيد مسافات (مع الحفاظ على الأسطر).
- **الحقول:** amount, currency(SAR), rawMerchant, type, source, cardLast4, balanceAfter, occurredAt, parseConfidence.
- **أنواع العمليات:** refund → withdrawal → transfer → income → payment (بهذا ترتيب الفحص).
- **confidence gating:** ضعيف → لا تصنيف صامت، اطلب تأكيد.
- **تجاهل غير المالي (§24.6):** أي رسالة بلا مبلغ + نوع واضح (OTP/عروض/تنبيه رصيد) → `ParseResult.notTransaction`.
- **De-dup (§24.5):** المكرّر = نفس المبلغ + نفس المتجر + الوقت ±دقيقتين (يُطبَّق في طبقة الـ repository، لا المحرك).
- **التواريخ:** تُخزَّن لاحقاً ميلادي UTC؛ المحرك يستخرج DateTime؛ معالجة الهجري/المنطقة الزمنية (Asia/Riyadh) في الطبقات الأعلى.
- **corpus:** عيّنات تمثيلية في `test/engine/fixtures/`. تُستبدَل/تُكمَّل بـ **رسائل حقيقية مجهّلة** قبل الإطلاق. عتبة golden: parse ≥90%.

---

## 8. Categorization Rules
- ترتيب القرار: **merchant_category_map (تأكيد المستخدم) → قاعدة النوع (withdrawal→سحب نقدي، transfer→تحويلات، income→دخل) → كلمات مفتاحية (بذور سعودية) → افتراضي (أخرى)**.
- التعلّم: عند تصحيح المستخدم مع «طبّق على كل العمليات» → `Categorizer.confirmMerchant` يحدّث الخريطة (وفي DB: `merchant_category_map.is_user_confirmed = true`).
- خيار «هذه العملية فقط» → يحدّث `transaction.category_id` دون لمس الخريطة.
- العتبة: تصنيف تلقائي ≥80% على الـ corpus.

---

## 9. Privacy Rules
- **كل المعالجة المالية on-device.** لا رفع بيانات مالية قابلة للقراءة.
- DB محلية **مشفّرة** (SQLCipher) — مفتاح في Keychain/Keystore.
- backend خفيف فقط: auth + backup blob (E2E) + مقاييس مجهولة + parsing_rules config.
- **المقاييس مجهولة تماماً:** لا مبالغ/متاجر/بريد مرتبط بسلوك مالي. opt-out متاح. القائمة في `PRODUCT_SPEC §25.12`.
- «حذف الحساب وكل بياناتي»: مسح DB محلي فوري + soft-delete 30 يوم للحساب/النسخة على السيرفر.
- `raw_message` يبقى محلياً فقط ولا يُرفع ضمن الـ backup.
- الرسالة الملزِمة: «الدخول لتحديد هويتك. بياناتك على جهازك. النسخ الاحتياطي اختياري ومشفّر E2E. الدخول ≠ مزامنة.»

---

## 10. Auth + Optional Encrypted Backup Rules
**Auth (MVP، أثناء onboarding):**
- Google Sign-In + Apple Sign-In (إلزامي على iOS بسبب Guideline 4.8) + Email/OTP (Amazon SES).
- iOS: Apple أولاً؛ Android: Google أولاً. تخزين JWT/refresh في Keychain/Keystore.
- بوابة عمر 18+.

**Backup (MVP، اختياري، Settings > Backup & Restore، مطفأ افتراضياً):**
- تفعيل من الإعدادات فقط → (1) شرح الخصوصية (2) توليد مفتاح K (3) طلب passphrase (4) عرض recovery code وإلزام بحفظه.
- التشفير: K مشتقّ من passphrase عبر **Argon2id** + **AES-256-GCM** محلياً قبل الرفع. السيرفر يخزّن `encrypted_blob` فقط.
- الاستعادة: عند الدخول على جهاز جديد **وكان هناك backup** → «استعادة نسختك المشفّرة؟» → passphrase/recovery → فكّ محلي → استرجاع كامل.
- بدون backup: الدخول لا يسترجع شيئاً (لا توجد نسخة) — متوقّع ويُوضَّح.
- ⚠️ فقد passphrase + recovery code = لا يمكن فكّ النسخة (E2E). يُعرض بوضوح.
- يُنسخ: transactions, budgets, goals, merchant_map, achievements, streaks, settings. **لا يُنسخ** `raw_message`.
- التفاصيل: `AUTH_AND_ADMIN_SPEC.md §4.6`.

---

## 11. Sprints 2 → 6 (نظرة عامة)
| Sprint | المحتوى |
|---|---|
| **2** | Local encrypted DB (Drift + SQLCipher) + seed + domain/repositories + usecases + repository tests |
| **3** | الالتقاط (Android SMS + iOS Share/Paste + يدوي) + Confirm sheet + Transactions/Details + Dashboard (= الـ Aha) |
| **4** | Budgets (تنبيهات 80/100) + Goals + Vault 2D (Rive) + Gamification (Streak/XP/Levels/Badges) + Achievements + notifications |
| **5** | Onboarding (نقل من النموذج) + Auth (Google/Apple/OTP) + Backup مشفّر اختياري + Settings + Privacy/حذف الحساب |
| **6** | Reports مبسّط + Subscription detector + accessibility pass + QA متعدد البنوك + closed beta |

> الـ backend (auth+backup+metrics+rules) يُبنى بالتوازي مع Sprint 5 كخدمة منفصلة.

---

## 12. Exact Prompts for Codex

**System prompt (الصِق في بداية كل جلسة):**
```
أنت مهندس Flutter senior تبني تطبيق تتبّع مصاريف عربي (RTL, Arabic-first).
المرجع الكامل في ملفات .md بجذر المستودع و CODEX_HANDOFF.md. القواعد غير القابلة للتفاوض (CODEX_HANDOFF §2):
- المعالجة المالية on-device؛ لا رفع بيانات مالية قابلة للقراءة.
- Login في MVP أثناء onboarding؛ Backup مشفّر E2E اختياري من Settings (مطفأ افتراضياً)؛ لا مزامنة realtime.
- المحرك (lib/engine) Dart نقي لا يستورد flutter؛ الواجهة لا تستورد الـ parser مباشرة (عبر usecases/repositories فقط).
- التزام حرفي بـ DESIGN_SYSTEM.md (Vibrant Fintech، بدون إيموجي، Lucide، IBM Plex Sans Arabic، RTL، tabular figures، WCAG AA، focus, reduce-motion).
- قواعد العمل PRODUCT_SPEC §24/§25 حرفياً (streak، dedup، «وفّرت» same-period، budget، backup…).
- لا إعلانات في MVP؛ لا Interstitial أبداً.
كل ميزة تأتي مع اختبارات. لا تكسر طبقات المعمارية. سلّم على دفعات صغيرة قابلة للمراجعة.
الأساس والمحرك واختباراته منجزة — لا تعِد بناءها. ابدأ من Sprint 2.
```

**Per-sprint task prompts** — انظر القسم 13 (لكل sprint برومبت + DoD). ابدأ بـ «Next immediate Codex task» في نهاية الملف.

---

## 13. Definition of Done (لكل Sprint)

**Sprint 2 — DB (التالي):**
- drift tables لكل جداول `PRODUCT_SPEC §14` + SQLCipher (مشفّرة at-rest) + migrations.
- seed: 20 تصنيف + بذور المتاجر + أهداف سعودية مقترحة.
- `domain/` (entities + repo interfaces + usecases) و`data/repositories/` (impl).
- usecases: addTransaction (مع **de-dup §24.5**), confirmTransaction, correctCategory (هذه/الكل → `Categorizer.confirmMerchant`), CRUD budgets/goals، الدخل مستثنى من الميزانيات.
- ربط Parser+Categorizer بالـ repository عبر usecase (الواجهة لا تلمس المحرك).
- اختبارات repository (in-memory drift) + تبقى اختبارات engine خضراء.
- **DoD:** `flutter analyze` نظيف + `flutter test` كله أخضر.

**Sprint 3 — Capture + Core UI:**
- Android SMS receiver (platform channel/another_telephony) + iOS Share/Shortcut + لصق/إدخال يدوي.
- مسار end-to-end: التقاط → parse → **Confirm bottom sheet** → حفظ → تحديث Dashboard.
- شاشات: Transactions (مجمّعة بالتاريخ، فلترة، وسم «غير مؤكدة») + Details + تعديل تصنيف (هذه/الكل).
- **DoD:** رسالة حقيقية واحدة تظهر في Dashboard (الـ Aha) + اختبارات widget/usecase.

**Sprint 4 — Budgets/Goals/Gamification:**
- Budgets (يومي/أسبوعي/شهري، ألوان safe/warning/over، تنبيهات 80/100، تصفير بتوقيت الرياض).
- Goals + **Vault 2D (Rive، property progress 0–100، نسخة static احتياطية)**.
- Gamification: Streak (§24.4) + جداول XP/Levels/Badges (§25.7) + streak freeze + Achievements + celebration overlay.
- Local notifications (§25.6) + quiet hours.
- **DoD:** الحلقة التحفيزية كاملة + اختبارات منطق (XP/streak/budget).

**Sprint 5 — Onboarding/Auth/Backup/Settings:**
- نقل Onboarding 1:1 من `prototype/onboarding-vibrant.html` إلى Flutter.
- Auth (Google/Apple/OTP) أثناء onboarding + بوابة عمر.
- Backup مشفّر E2E اختياري من Settings (§4.6) + Restore على جهاز جديد.
- Settings + Privacy & Data + حذف الحساب (soft-delete 30 يوم) + opt-out المقاييس.
- **DoD:** رحلة كاملة Splash→Dashboard + تفعيل backup واستعادته على جهاز آخر.

**Sprint 6 — Polish/QA/Beta:**
- Reports مبسّط (أسبوعي/شهري) + Subscription detector + accessibility pass كامل + اختبار متعدد البنوك على corpus حقيقي + closed beta (السعودية).
- **DoD:** جاهز لـ beta + golden ≥90% parse / ≥80% تصنيف على corpus حقيقي.

---

## 14. Testing Requirements
- **كل PR/دفعة:** `flutter analyze` (صفر errors) + `flutter test` (كله أخضر، بما فيه `test/engine`).
- المحرك: golden tests (parse ≥90%, تصنيف ≥80%) — توسّع الـ corpus مع كل بنك.
- DB: اختبارات repository بـ in-memory drift.
- Usecases: unit tests (de-dup، confirm، correctCategory، budget recompute، streak/XP).
- UI الحرجة: widget tests (Confirm sheet، Dashboard، Budgets states).
- لا دمج إن كسرت اختبارات قائمة.

---

## 15. What NOT to Build Yet
- ❌ أي **إعلانات** (وممنوع Interstitial نهائياً).
- ❌ **مزامنة realtime** أو مشاركة اجتماعية/leaderboards.
- ❌ **Voice input** (Phase 2 — جهّز Input Layer ليقبله لاحقاً فقط).
- ❌ **Offers/Coupons/Affiliate** (Phase 2).
- ❌ تقارير مفصّلة معقّدة / تصدير PDF (المبسّط فقط في MVP؛ CSV أولوية S).
- ❌ تعدّد حسابات/بطاقات متقدّم.
- ❌ ML categorization (ابدأ rules؛ ML لاحقاً).
- ❌ خزنة 3D (استخدم 2D + حركة خفيفة).
- ❌ لوحة الأدمن داخل تطبيق الموبايل (هي ويب منفصلة، خارج هذا التطبيق).
- ❌ Light/Dark «الاثنين» مطلوبان أصلاً — لا تحذف أحدهما.

---

## ⭐ Next Immediate Codex Task — Sprint 2

> **Local encrypted database with Drift + SQLCipher + repository tests.**

**Prompt للّصق (بعد System prompt §12):**
```
المشروع في app/. الأساس والمحرك واختباراته منجزة (lib/core, lib/engine, test/engine) — لا تعِد بناءها وأبقِ اختبارات engine خضراء.

نفّذ Sprint 2 (DB):
1) فعّل في pubspec: drift, sqlite3_flutter_libs, sqlcipher_flutter_libs, dev: drift_dev, build_runner. شغّل pub get.
2) أنشئ lib/data/db/ : قاعدة Drift مشفّرة بـ SQLCipher (مفتاح من flutter_secure_storage / Keychain-Keystore) بجداول PRODUCT_SPEC §14:
   transactions, merchants, merchant_category_map, categories, budgets, goals, goal_contributions, achievements, streaks, subscriptions, user_settings, parsing_rules.
   راعِ الحقول كما في §14 (status: confirmed|pending|ignored، type، source، card_last4، balance_after، occurred_at، raw_message، parse_confidence…).
3) Seed عند أول تشغيل: التصنيفات الـ20 من lib/engine/categorization/category.dart + بذور المتاجر من category_seeds.dart (is_user_confirmed=false) + أهداف سعودية مقترحة (رحلة صيف، صندوق طوارئ، الحج/العمرة…).
4) lib/domain/: entities + repository interfaces + usecases:
   - AddTransaction: يستدعي ParserEngine ثم Categorizer عبر usecase، يطبّق de-dup (§24.5: نفس المبلغ+المتجر+الوقت±دقيقتين) → status confirmed/pending حسب confidence.
   - ConfirmTransaction، CorrectCategory (خيار «هذه العملية فقط» يحدّث transaction.category_id؛ «كل العمليات» يستدعي Categorizer.confirmMerchant + يحدّث merchant_category_map.is_user_confirmed=true).
   - CRUD للميزانيات والأهداف (الدخل type=income مستثنى من حسابات الميزانية).
5) lib/data/repositories/: implementations تربط DB + المحرك. الواجهة لا تستورد engine/parser مباشرة — فقط عبر usecases/repositories.
6) اختبارات: repository_test بـ in-memory Drift (NativeDatabase.memory) تغطي add/dedup/confirm/correctCategory/budget+goal CRUD. + أبقِ test/engine خضراء.
7) شغّل flutter analyze (صفر errors) و flutter test (كله أخضر) و build_runner build.

DoD: analyze نظيف + كل الاختبارات خضراء + DB مشفّرة + seed يعمل. لا تبنِ أي شاشات منتج في هذا الـ sprint (foundation_home_screen تبقى مؤقتة).
```

بعد إنهاء Sprint 2 ومراجعته → انتقل إلى Sprint 3 (Capture + Confirm + Dashboard) بنفس الأسلوب من القسم 13.

---

## ⭐ تحديث الحالة (بعد Sprint 2 + جزء من Sprint 3)
**منجز:** Sprint 0 + 1 + 2، و**قلب Sprint 3** (مسار اللصق اليدوي → Confirm → Dashboard → Transactions → Details → تغيير تصنيف). موجود:
- queries قراءة في `TransactionRepository` (getRecent/getAll/expenseTotalBetween/categoryBreakdown) + `CategoryRepository`.
- presentation: `features/app/app_shell.dart` (bottom nav 5 + FAB), `features/dashboard/*`, `features/transactions/*` (+ widgets: confirm_transaction_sheet, change_category_sheet), `features/capture/manual_paste_screen.dart`, `features/common/*` (category_catalog, widgets, vault_widget).
- utils: `core/utils/app_lucide_icons.dart` (أسماء أيقونات موحّدة — **استخدمه دائماً، لا تستورد lucide_icons مباشرة**)، `formatters.dart`، `lucide_icon_map.dart`.
- router: `/` (AppShell) · `/paste` · `/transaction/:id`.
- providers: `core/di/app_providers.dart` + `categoryCatalogProvider` + `dashboardDataProvider` + `transactionsListProvider` + `transactionByIdProvider`.

**قواعد إضافية لازم تتبعها:**
- استخدم `AppLucideIcons` لكل الأيقونات (لا `lucide_icons` مباشرة).
- بعد أي تعديل بيانات: `refreshTransactions(ref)` + `ref.invalidate(dashboardDataProvider)`.
- `AddTransactionUseCase` يقبل `rawMessage` + `senderId?` ويرجّع added/duplicate/notTransaction — كل مصادر الالتقاط تمرّ عبره.

---

## ⭐ NEXT TASK A — إكمال Sprint 3 (Native Capture)
**Prompt للّصق (بعد System prompt §12):**
```
المشروع في app/ وقلب Sprint 3 منجز (اللصق اليدوي → Confirm → Dashboard). لا تعِد بناءه.
أكمل الالتقاط الأصلي (native) بحيث يمرّ كل شيء عبر AddTransactionUseCase(rawMessage, senderId).

1) توليد المنصّات: شغّل `flutter create .` داخل app/ (يحافظ على lib/ و test/). ثم flutter pub get.

2) Android SMS auto-capture:
   - فعّل another_telephony في pubspec.
   - أضف صلاحيات RECEIVE_SMS/READ_SMS في AndroidManifest + شاشة rationale قبل الطلب (WIREFRAMES A5-Android).
   - استمع للرسائل الواردة (foreground + background handler منفصل top-level).
   - عند وصول رسالة: استدعِ AddTransactionUseCase(rawMessage: body, senderId: address).
       added + (pending أو متجر جديد) → إشعار محلي "أكّد عملية" يفتح showConfirmTransactionSheet.
       added + confirmed → إشعار خفيف فقط.
       duplicate/notTransaction → تجاهل بصمت (§24.6).
   - عالج التشغيل من إشعار → فتح الـ Confirm sheet للـ transactionId.

3) iOS Share + Shortcut:
   - Share Extension target (نص فقط) يكتب إلى App Group shared container.
   - التطبيق عند launch/resume يقرأ المعلّق ويستدعي AddTransactionUseCase ثم يفتح Confirm.
   - App Intent (Shortcuts) "أضف رسالة بنك" يمرّر النص لنفس المسار.

4) ربط شاشة "طريقة الإدخال" (onboarding A5) لاحقاً في Sprint 5؛ الآن وفّر نقطة دخول مؤقتة في الإعدادات/الـ FAB لتفعيل صلاحية SMS على Android.

5) اختبارات:
   - unit test: محاكاة وصول رسالة (تمرير body/senderId لـ AddTransactionUseCase) → عملية محفوظة/مكررة/متجاهلة.
   - widget test (اختياري): ضبط GoogleFonts.config.allowRuntimeFetching=false، واستخدم tester.pump (وليس pumpAndSettle بسبب حركة الخزنة المتكررة).

DoD: flutter analyze نظيف + flutter test أخضر + التقاط SMS حقيقي على Android يفتح Confirm. حافظ على عزل الطبقات (الواجهة/الـ receiver لا يستوردان engine/parser مباشرة).
```

---

## ⭐ NEXT TASK B — Sprint 4 (Budgets + Goals + Vault + Gamification)
**Prompt للّصق:**
```
المشروع في app/. نفّذ Sprint 4 (PRODUCT_SPEC §13/§24/§25 + WIREFRAMES B5–B8, B11). جداول budgets/goals/goal_contributions/streaks/xp_levels/achievements موجودة، وBudget/Goal repos + usecases (save/delete/addContribution) موجودة.

1) Budgets:
   - usecase BudgetProgress: المصروف في الفترة الحالية لكل تصنيف (period: daily/weekly/monthly)، النسبة، الحالة (safe<80 / warning 80–99 / over≥100).
   - تصفير: يومي منتصف الليل Asia/Riyadh، أسبوعي يبدأ السبت، شهري أول الشهر الميلادي.
   - شاشات: Budgets (بطاقات + Budget Bar بألوان c.budgetState)، Create/Edit Budget (تصنيف+مبلغ+دورية).
   - تنبيهات: عند عبور 80% و100% أطلق إشعاراً واضبط alert_80_sent/alert_100_sent (مرة واحدة لكل فترة).

2) Goals + Vault:
   - شاشات: Goals (قائمة ببطاقات خزنة مصغّرة)، Goal Details (VaultWidget كبير + المساهمات + "أضف للهدف")، Add Goal (الاسم/المبلغ/المدة + مبلغ موصى به أسبوعياً/شهرياً).
   - استخدم VaultWidget الحالي (2D). Rive لاحقاً.

3) Gamification (الجداول موجودة، أنشئ repos/services + usecases):
   - Streak (§24.4): مراجعة/إضافة عملية واحدة يومياً تحافظ عليه؛ timezone الرياض؛ streak freeze واحد أسبوعياً تلقائي. حدّث current/longest/last_active_date.
   - XP + Levels (§25.7): جدول XP لكل فعل + عتبات المستويات (مبتدئ0/منظّم200/موفّر ذكي600/خبير1500/أسطورة3500). XpService يحدّث xp_levels.
   - Badges (§25.7): منطق فتح الشارات في achievements (أول ميزانية/7 أيام/شهر بلا تجاوز/وفّرت500/أول هدف/قللت المطاعم20%).
   - اربط منح XP/streak بأحداث: تأكيد عملية، تصحيح تصنيف، البقاء ضمن ميزانية اليوم، milestone هدف، تحدي أسبوعي.
   - شاشة Achievements (شبكة شارات + شريط XP + المستوى) + Celebration overlay عند milestone (يُغلق تلقائياً، يحترم reduce-motion).
   - حدّث streak pill في الـ Dashboard ليقرأ القيمة الحقيقية (حالياً 0 ثابت).

4) Notifications (infra): flutter_local_notifications + timezone. أنواع §25.6 + ساعات هدوء 11م–8ص (تأجيل). per-type toggles تُخزَّن في user_settings.notifications_json.

5) اختبارات unit: BudgetProgress (نسب/حالات/تصفير)، Streak (يومي/freeze/timezone)، XP/Level thresholds، Badge unlock. + أبقِ كل الاختبارات السابقة خضراء.

DoD: flutter analyze نظيف + flutter test أخضر + الحلقة التحفيزية تعمل (إضافة عملية → XP/streak يتحدّثان، ميزانية تتجاوز → تنبيه، هدف يمتلئ → احتفال). التزم بـ DESIGN_SYSTEM + بدون إيموجي + AppLucideIcons + RTL.
```

