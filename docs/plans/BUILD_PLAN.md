# خطة التنفيذ وبدء المشروع (Build Plan & Codex Handoff)

> الهدف: تحويل المواصفات إلى تطبيق Flutter حقيقي. هذا الملف هو **دليل التنفيذ + بريف الـ coding agent (Codex)**.
> المرجعيات: docs/specs/PRODUCT_SPEC.md · docs/specs/SAUDI_MARKET_SPEC.md · docs/specs/AUTH_AND_ADMIN_SPEC.md · DESIGN_SYSTEM.md · docs/design/WIREFRAMES.md · prototype/onboarding-vibrant.html

---

## 0. المبدأ الموجّه
1. **المحرك أولاً (Engine-first):** Parser + Categorization كـ **Dart نقي** معزول عن الواجهة، مع golden tests. هذا قلب المنتج.
2. **مسارَان متوازيان:** المحرك+DB (المسار الحرج) | الواجهة من النموذج الجاهز (التصميم محسوم).
3. **بدون رفع بيانات مالية:** كل المعالجة on-device. Backend خفيف فقط (auth + backup blob + metrics + rules).

---

## 1. بيئة العمل (Prerequisites)
- Flutter SDK (آخر stable) + Dart.
- Android Studio + Xcode (للـ iOS).
- جهاز/محاكي Android (لاختبار SMS) + iPhone (لاختبار Share).
- حساب Apple Developer + Google Play Console (للنشر لاحقاً).
- **مهمة موازية فوراً:** بدء جمع **Corpus** رسائل حقيقية (SNB, الراجحي, الرياض, STC Pay) — blocker للمحرك.

## 2. الحزم (Dependencies — pubspec)
```yaml
# State & DI
flutter_riverpod
# Routing
go_router
# DB (مشفّر)
drift, sqlite3_flutter_libs, sqlcipher_flutter_libs
# Models
freezed, json_serializable, build_runner
# Secure storage / keys
flutter_secure_storage
# Android SMS capture
another_telephony   # أو platform channel مخصّص
# Auth (V… MVP)
google_sign_in, sign_in_with_apple
# Network (auth/backup/rules/metrics)
dio
# Notifications
flutter_local_notifications, timezone
# Animation (الخزنة)
rive            # أو lottie
# UI
google_fonts            # IBM Plex Sans Arabic
lucide_icons            # أيقونات Lucide
# i18n
flutter_localizations (sdk), intl
# Crypto (backup E2E)
cryptography            # AES-GCM + Argon2
# Tests
flutter_test, mocktail
```

## 3. بنية المشروع (Architecture — feature-first + layers)
```
lib/
  core/
    theme/            # tokens من DESIGN_SYSTEM.md (AppColors, AppTypography, AppSpacing)
    router/           # go_router
    constants/  utils/  di/
  engine/             # ★ Dart نقي — لا يستورد flutter
    parser/           # normalizer + bank profiles + extractors
    categorization/   # keywords + merchant_map + learning
    models/           # ParsedTransaction DTO, enums
  data/
    db/               # drift tables + daos + migrations + seed
    repositories/     # implementations
    remote/           # auth, backup, rules, metrics clients (dio)
  domain/
    entities/  repositories/  usecases/
  features/
    onboarding/  auth/  dashboard/  transactions/  budgets/
    goals/  gamification/  subscriptions/  reports/  settings/  backup/
  l10n/               # ar (افتراضي)
test/
  engine/             # ★ golden tests على corpus
```
**قاعدة صارمة:** `features/*` و`data/*` لا يستوردان `engine/parser` مباشرة — عبر usecases/repositories فقط.

## 4. خارطة الـ Sprints (مع Definition of Done)

### Sprint 0 — التأسيس (3–4 أيام)
- `flutter create` + بنية المجلدات + git + CI (analyze + test).
- `core/theme` من DESIGN_SYSTEM.md (الألوان/الخطوط/المسافات للوضعين).
- إعداد Riverpod + go_router + drift skeleton.
- بدء جمع الـ corpus.
- **DoD:** التطبيق يبني ويعرض شاشة فارغة بالثيم الصحيح؛ CI أخضر.

### Sprint 1 — المحرك (Engine) ★ (5–7 أيام)
- `engine/parser`: Normalizer (أرقام هندية→غربية، عملة، تواريخ هجري/ميلادي) + bank profiles لـ P0 + extractors + confidence.
- `engine/categorization`: keywords + merchant_map + learning + بذور سعودية.
- **golden tests** على corpus (هدف ≥90% parse, ≥80% تصنيف).
- **DoD:** `flutter test test/engine` يمر بالعتبات؛ المحرك يعمل بلا أي واجهة.

### Sprint 2 — قاعدة البيانات (4–5 أيام)
- drift tables (كل الجداول من PRODUCT_SPEC §14) + SQLCipher + migrations + seed (categories, merchant_map, goals).
- repositories + usecases (add/confirm/correct transaction, budgets, goals…).
- **DoD:** اختبارات repository تمر؛ DB مشفّرة on-device.

### Sprint 3 — الالتقاط والشاشات الأساسية (7–9 أيام)
- Android SMS receiver (platform channel) + iOS Share/Paste + الإدخال اليدوي.
- مسار end-to-end: التقاط → parse → **Confirm sheet** → حفظ → **Dashboard**.
- شاشات: Transactions + Details + تعديل تصنيف.
- **DoD:** عملية واحدة من رسالة حقيقية تظهر في Dashboard (= الـ Aha).

### Sprint 4 — الميزانيات والأهداف والتلعيب (7–9 أيام)
- Budgets + تنبيهات 80/100 · Goals + **الخزنة 2D (Rive)** · Streak/XP/Levels/Badges (جداول §25.7) · Achievements + احتفالات.
- Local notifications (§25.6).
- **DoD:** الحلقة التحفيزية كاملة وتعمل.

### Sprint 5 — Onboarding + Auth + Backup + Settings (6–8 أيام)
- Onboarding من `prototype/onboarding-vibrant.html` (نقل 1:1 إلى Flutter).
- Auth (Google/Apple/OTP) أثناء onboarding.
- **Backup مشفّر E2E اختياري** من الإعدادات (AUTH §4.6) + Restore.
- Settings + Privacy & Data + حذف الحساب (soft-delete).
- **DoD:** رحلة المستخدم الكاملة من Splash إلى Dashboard + تفعيل backup واستعادته.

### Sprint 6 — صقل + QA + Beta (5–7 أيام)
- Reports مبسّط + Subscription detector + accessibility pass + اختبار متعدد البنوك + closed beta (السعودية).
- **DoD:** جاهز لـ beta مغلقة.

> backend (auth+backup+metrics+rules) يُبنى بالتوازي مع Sprint 5 (خدمة منفصلة).

## 5. ترتيب البناء الأول (ابدأ بهذا حرفياً)
1. التحقق من سياسة Google Play SMS (موازٍ، لا يحجب الكود).
2. Sprint 0 scaffold + theme tokens.
3. Sprint 1 المحرك + golden tests ← **أهم خطوة**.
4. مسار «عملية واحدة → Dashboard» (Sprints 2–3) ← يثبت المنتج.

---

## 6. بريف Codex (Handoff Brief)

### 6.1 System prompt للـ agent (الصِق في بداية الجلسة)
```
أنت مهندس Flutter senior تبني تطبيق تتبّع مصاريف عربي (RTL, Arabic-first).
المرجع الكامل في ملفات .md بالمستودع. القواعد غير القابلة للتفاوض:
- المعالجة المالية on-device فقط؛ لا رفع بيانات مالية قابلة للقراءة.
- المحرك (engine/) Dart نقي معزول عن الواجهة، يُختبر بـ golden tests.
- الالتزام الحرفي بـ DESIGN_SYSTEM.md (ألوان/خطوط/مكوّنات) — Vibrant Fintech، بدون إيموجي، أيقونات Lucide، IBM Plex Sans Arabic.
- RTL أصيل، tabular figures للمبالغ، WCAG AA، focus states، reduce-motion.
- اتبع قواعد العمل في docs/specs/PRODUCT_SPEC.md §24 و§25 حرفياً (streak، dedup، «وفّرت»، backup اختياري…).
- كل ميزة تأتي مع اختبارات. لا تخلط بين طبقات المعمارية (§3).
سلّم على دفعات صغيرة قابلة للمراجعة، وابدأ بالمحرك.
```

### 6.2 أول 3 مهام (Task Prompts جاهزة)
**Task 1 — Scaffold:**
> «أنشئ مشروع Flutter بالبنية في docs/plans/BUILD_PLAN.md §3، أضف الحزم في §2، ونفّذ `core/theme` (AppColors, AppTypography, AppSpacing) حرفياً من DESIGN_SYSTEM.md للوضعين Light/Dark. أضف Riverpod + go_router + drift skeleton. هدف: التطبيق يبني ويعرض شاشة فارغة بالثيم الصحيح + CI (analyze+test).»

**Task 2 — Parser Engine:**
> «نفّذ `engine/parser` كـ Dart نقي: Normalizer (أرقام هندية→غربية، توحيد SAR، تواريخ هجري/ميلادي)، bank profiles لـ snb/alrajhi/riyad/stcpay من docs/specs/SAUDI_MARKET_SPEC.md، extractors لكل حقل مع parse_confidence، وreturns ParsedTransaction DTO. اكتب golden tests في `test/engine` على عينات الرسائل. عتبة ≥90%.»

**Task 3 — Categorization Engine:**
> «نفّذ `engine/categorization`: keywords + merchant_category_map + التعلّم من تصحيح المستخدم، مع البذور السعودية من docs/specs/SAUDI_MARKET_SPEC.md §6. اربطه بالـ parser عبر DTO فقط. golden tests للتصنيف، عتبة ≥80%.»

### 6.3 قاعدة المراجعة
بعد كل مهمة: شغّل `flutter analyze` + `flutter test`، راجع الـ diff، تأكّد من عدم كسر طبقات المعمارية وقواعد §24/§25.

---

## 7. ما الذي يفعله كل طرف الآن
| الطرف | المهمة |
|---|---|
| **أنت (المالك)** | تجهيز حسابات المطورين + بدء جمع corpus + التحقق من Google Play SMS |
| **Codex** | Sprint 0 → 1 → 2 (scaffold + المحرك + DB) بالبريف أعلاه |
| **المراجعة** | بعد كل دفعة: تشغيل الاختبارات + مطابقة المواصفات |

> **الخطوة التالية الفورية:** افتح Codex، الصِق System prompt (§6.1) + Task 1 (§6.2)، ودعه يبدأ الـ scaffold.
