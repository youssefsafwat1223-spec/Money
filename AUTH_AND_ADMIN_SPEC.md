# ملحق المصادقة ولوحة الأدمن (Auth & Admin Spec)

> ✅ **حالة التنفيذ (نهائية):** المصادقة **في MVP أثناء onboarding** (هوية من اليوم الأول). الـ Backup المشفّر **في MVP لكنه اختياري ومطفأ افتراضياً** ويُفعّل من Settings. **الدخول والـ Backup مفهومان منفصلان** — بدون backup لا تغادر البيانات الجهاز.

---

## 0. قرارات محسومة (Decisions Locked)
| القرار | القيمة | السريان |
|---|---|---|
| الإيموجي | **ممنوع نهائياً** — أيقونات موحّدة | MVP |
| نطاق الأدمن | **مقاييس مجمّعة ومجهولة فقط** — لا بيانات مالية فردية | MVP |
| طرق الدخول | **Google + Apple + بريد/OTP** | MVP |
| توقيت الدخول | **أثناء onboarding** (هوية من اليوم الأول) | MVP |
| Backup سحابي | **اختياري + مطفأ افتراضياً** — يُفعّل من Settings؛ مشفّر E2E، السيرفر يحفظ blob فقط | MVP |
| فصل المفهومين | **الدخول ≠ مزامنة البيانات** — بدون backup لا تغادر البيانات الجهاز | MVP |

---

## 1. قاعدة «بدون إيموجي» (No-Emoji Design Rule)

- لا إيموجي في أي شاشة، إشعار، أو نص داخل التطبيق.
- كل رمز = أيقونة من **مكتبة أيقونات واحدة موحّدة** (مثل Lucide / Phosphor / مجموعة مخصّصة) بأسلوب واحد (outline أو duotone).
- التصنيفات الـ20 لها أيقونات مرسومة (مطاعم، بقالة، وقود...) لا إيموجي.
- Streak/XP/الخزنة/الاحتفالات → أصول رسومية (Rive/SVG) لا إيموجي.
- في الـ wireframes السابقة (WIREFRAMES.md) أي إيموجي = **placeholder** يُستبدل بأيقونة مسمّاة. التعويض:
  - 🔥 streak → `icon/flame`
  - 🎯 هدف → `icon/target`
  - 💡 insight → `icon/lightbulb`
  - 🍔🛒⛽ تصنيفات → أيقونات التصنيفات المسمّاة
  - ⚠️ غير مؤكدة → `icon/alert`
  - 🔒 خصوصية/قفل → `icon/lock`

---

## 2. وعد الخصوصية المُحدَّث (Revised Privacy Promise)

> الصياغة القديمة «لا سيرفر إطلاقاً» لم تعد دقيقة بعد إضافة الدخول. الصياغة الجديدة الملزِمة:

**«بياناتك المالية تبقى على جهازك ولا تُرفع أبداً. نحفظ فقط بريد دخولك وإحصاءات استخدام مجهولة لتحسين التطبيق.»**

ما **يُرفع** للسيرفر:
- هوية الحساب: Google ID أو البريد + حالة التحقق.
- مقاييس مجهولة مجمّعة (مفصّلة في القسم 6).
- (لاحقاً، اختياري) backup مشفّر end-to-end لا نملك مفتاحه.

ما **لا يُرفع أبداً**:
- نص رسائل البنك (`raw_message`).
- العمليات، المبالغ، أسماء المتاجر المرتبطة بالمستخدم.
- الأرصدة، أرقام البطاقات، الميزانيات، الأهداف الشخصية.

> المبدأ التقني: المقاييس المجهولة تُجمَّع **client-side** وتُرسَل **مفصولة عن هوية المستخدم** قدر الإمكان (لا join بين financial content و user identity على السيرفر).

---

## 3. معمارية المصادقة (Auth Architecture)

```
[App] ──(OAuth/OTP)──> [Auth Service]  ──> users (id, email, google_id, apple_id, verified, created_at)
  │                          │
  │  JWT (access + refresh)  │
  │<─────────────────────────┘
  │
  │  المعالجة المالية + DB ── on-device فقط (لا تمسّ السيرفر)
  │
  └──(مقاييس مجهولة)──> [Metrics Ingestion] ──> aggregated_metrics (بلا هوية مالية)
                                                      │
[Admin Web] ──(admin JWT + RBAC)──────────────────> reads aggregates only
```

### مكوّنات الـ Backend (خفيف)
| الخدمة | المسؤولية | ماذا تخزّن |
|---|---|---|
| **Auth Service** | تسجيل/دخول، إصدار JWT، تحقق OTP | users, sessions, otp_codes |
| **Metrics Ingestion** | استقبال أحداث مجهولة | aggregated_metrics, daily_rollups |
| **Rules Config** | تقديم parsing_rules للتحديث عن بُعد | bank_rules (نسخ) |
| **Admin API** | قراءة المجاميع فقط + إدارة rules | — (read-mostly) |

التوصية التقنية: backend بسيط (Node/NestJS أو Go) + Postgres + Redis (لـ OTP/rate-limit). استضافة في منطقة قريبة (الرياض/الخليج) لتقليل latency والامتثال.

---

## 4. تدفقات الدخول (Auth Flows)

### 4.1 ترتيب Onboarding المُحدَّث
```
Splash → Intro×3 → اختيار دولة/عملة → الخصوصية
   → [شاشة الدخول الإجباري]  ← جديد، قبل أي استخدام
        ├─ Google Sign-In (نقرة واحدة)
        └─ بريد + OTP
   → طريقة الإدخال (Android/iOS) → أول ميزانية (اختياري) → Dashboard
```

### 4.2 Google Sign-In (لا OTP)
```
المستخدم يضغط "المتابعة مع Google"
 → Google OAuth (SDK رسمي)
 → السيرفر يتحقق من id_token من جوجل
 → upsert user (google_id) → verified=true فوراً
 → إصدار JWT (access 15د + refresh 30يوم)
 → دخول مباشر (لا كود)
```

### 4.2b Apple Sign-In (لا OTP) — مطلوب على iOS
```
المستخدم يضغط "المتابعة مع Apple"
 → Sign in with Apple (ASAuthorization)
 → السيرفر يتحقق من identity_token (JWT موقّع من Apple)
 → upsert user (apple_id) → verified=true فوراً
 → إصدار JWT → دخول مباشر
```
> ملاحظة سياسة App Store (Guideline 4.8): **متى وُجد Google Sign-In، يصبح Apple Sign-In إلزامياً على iOS** وإلا يُرفض التطبيق. لذلك Apple Sign-In ليس خياراً تجميلياً — هو شرط نشر.
> خصوصية Apple: المستخدم قد يخفي بريده (Hide My Email → relay). نتعامل مع البريد الـ relay كبريد صالح ولا نطلب بريداً حقيقياً.
> ظهور الأزرار: على iOS نضع **Apple أولاً** ثم Google ثم البريد. على Android نضع Google أولاً (Apple Sign-In متاح كـ web flow لكنه ثانوي).

### 4.3 بريد + OTP
```
المستخدم يدخل البريد
 → السيرفر يولّد كود 6 أرقام، يخزّنه hashed مع TTL=10د، rate-limit
 → يرسل الكود عبر مزوّد إيميل (SES/Resend/Postmark)
 → المستخدم يدخل الكود
 → تحقق (≤5 محاولات) → verified=true → إصدار JWT
 → إعادة إرسال متاحة بعد 30ث
```

> توضيح مهم: **Google Sign-In لا يحتاج OTP** (جوجل تتحقق أصلاً). الـ OTP فقط لمسار البريد.

### 4.4 جلسات وتجديد
- Access token (JWT) قصير + Refresh token دوّار (rotating).
- تخزين التوكنات في **Keychain (iOS) / Keystore (Android)** فقط — لا shared prefs.
- خروج من كل الأجهزة، حذف الحساب (يمسح هوية السيرفر؛ البيانات المالية على الجهاز تُمسح بـ"حذف بياناتي").

---

## 4.6 الـ Backup المشفّر والاستعادة (Encrypted Backup & Restore) — MVP

### المبدأ
البيانات المالية تبقى المصدر الرئيسي على الجهاز. **الـ Backup اختياري ومطفأ افتراضياً** — يُفعَّل يدوياً من **Settings > Backup & Restore** (ليس أثناء onboarding). عند التفعيل ترفع **blob مشفّر end-to-end** لا يستطيع السيرفر قراءته.

### تفعيل الـ Backup (من الإعدادات فقط)
```
Settings > Backup & Restore > [تفعيل النسخ الاحتياطي]
 → شرح نموذج الخصوصية (E2E، لا نقرأ بياناتك)
 → توليد إعداد التشفير (K)
 → طلب passphrase من المستخدم
 → عرض recovery code + إلزام بحفظه (تأكيد ▢)
 → أول رفع blob مشفّر
```

### التشفير (E2E)
- مفتاح التشفير `K` يُشتقّ محلياً من **passphrase المستخدم** عبر **Argon2id** (أو مفتاح عشوائي يُحفظ في iCloud/Google Keychain).
- البيانات تُشفَّر محلياً بـ **AES-256-GCM** قبل الرفع.
- السيرفر يخزّن: `user_id, encrypted_blob, version, updated_at` فقط. **لا يملك K.**

### تدفّق النسخ والاستعادة
```
النسخ: تغيّر بيانات → تشفير محلي بـ K → رفع blob (تلقائي دوري + يدوي)
الاستعادة (جهاز جديد): دخول بنفس الحساب → "يوجد backup" → إدخال passphrase/جلب K
  → تنزيل blob → فكّ تشفير محلي → استرجاع كامل (عمليات/ميزانيات/أهداف/streak/XP)
```

### استرداد المفتاح (Key Recovery) — حرج
- (أ) **Recovery code** يُعرض مرة عند التفعيل · (ب) ربط K بـ **iCloud Keychain / Google Block Store**.
- ⚠️ **تحذير صريح:** فقد الـ passphrase + الـ recovery code = لا يمكن فكّ النسخة (E2E، لا نملك المفتاح). يُعرض بوضوح عند التفعيل.

### ماذا يُنسخ
- يُنسخ: transactions, budgets, goals, merchant_map, achievements, streaks, settings.
- لا يُنسخ: `raw_message` (يبقى محلياً فقط) لتقليل الحساسية.

### جدول السيرفر
```sql
backups(
  id PK, user_id FK, encrypted_blob BYTEA, blob_version INT,
  size_bytes INT, updated_at, device_info
)
```

---

## 5. شاشات المصادقة (Wireframes — بدون إيموجi)

### Auth-1. شاشة الدخول
> ترتيب الأزرار يتكيّف مع المنصة: **iOS → Apple أولاً**؛ **Android → Google أولاً**.

```
┌─────────────────────────────┐   (مثال على iOS)
│         [ شعار التطبيق ]     │
│      سجّل دخولك للبدء         │
│   بياناتك المالية تبقى على    │
│   جهازك — نحفظ بريدك فقط      │
│                             │
│ [ (Apple)  المتابعة مع Apple ]│  ← أساسي على iOS
│ [ (G)   المتابعة مع Google ] │
│                             │
│ ──────  أو  ──────          │
│                             │
│  البريد الإلكتروني           │
│  [ name@example.com       ] │
│  [ إرسال رمز الدخول ]       │
│                             │
│  بالمتابعة توافق على         │
│  [الشروط] و [الخصوصية]       │
└─────────────────────────────┘
```
> على Android: نفس الشاشة لكن Google أولاً وApple يظهر كخيار ثانوي (web flow). الأيقونات شعارات رسمية للمزوّدين (ليست إيموجي).

### Auth-2. إدخال OTP
```
┌─────────────────────────────┐
│ ‹                           │
│   أدخل رمز التحقق            │
│   أرسلنا كوداً إلى            │
│   name@example.com          │
│                             │
│   [ _ ][ _ ][ _ ][ _ ][ _ ][ _ ]│  ← 6 خانات
│                             │
│   إعادة الإرسال خلال 0:30    │  ← عدّاد
│   [ تغيير البريد ]          │
│                             │
│        [ تأكيد ]            │
└─────────────────────────────┘
```
- States: كود خاطئ (اهتزاز + «الرمز غير صحيح») · انتهت الصلاحية («انتهى الرمز، أعد الإرسال») · محاولات كثيرة (قفل مؤقت + رسالة).

---

## 6. لوحة الأدمن (Admin Dashboard — مقاييس مجمّعة مجهولة)

### 6.1 المبدأ
لوحة **ويب** منفصلة (مش داخل تطبيق الموبايل)، تقرأ **مجاميع** فقط. لا تستطيع رؤية مستخدم فرد أو عملية فردية. كل رقم = aggregate عبر شريحة (دولة/بنك/يوم).

### 6.2 المقاييس المعروضة
| المجموعة | أمثلة المقاييس |
|---|---|
| **النمو** | إجمالي المستخدمين، نشطون يومي/أسبوعي (DAU/WAU)، تسجيلات جديدة، retention D1/D7/D30 |
| **التفعيل** | نسبة من وصلوا للـ Aha (أول عملية مؤكدة)، نسبة تفعيل صلاحية SMS (Android) |
| **صحة المحرك** | **نسبة نجاح الـ parsing لكل bank_key**، عدد الرسائل pending، نسبة التصحيح اليدوي |
| **سلوك مجمّع** | توزيع التصنيفات إجمالاً (٪)، متوسط عدد العمليات/مستخدم — **بلا مبالغ مرتبطة بأفراد** |
| **التلعيب** | متوسط الـ streak، توزيع المستويات، أكثر الشارات فتحاً |
| **التقني** | crash rate، إصدارات التطبيق، أخطاء parsing شائعة (بلا نص رسالة) |

> قاعدة صارمة: **لا قيم مالية فردية، لا أسماء، لا بريد مرتبط بسلوك مالي.** المبالغ تُعرض فقط كنِسب/متوسطات مجمّعة على مستوى السوق.

### 6.3 شاشات الأدمن
```
Admin Web:
  Login (admin SSO + 2FA)
  Overview        → KPIs نمو + رسوم اتجاه
  Engine Health   → نجاح parsing/بنك + قائمة أنماط فاشلة (مجهولة)
  Rules Manager   → تحرير/نشر parsing_rules عن بُعد (versioned)
  Categories      → توزيع التصنيفات المجمّع
  Gamification    → streaks/levels/badges aggregates
  Users (count)   → أعداد وشرائح فقط — لا تفاصيل فرد
  Audit Log       → من غيّر أي rule ومتى
```

### 6.4 RBAC (أدوار)
- `super_admin` — كل شيء + إدارة الأدمنز.
- `analyst` — قراءة المجاميع فقط.
- `rules_editor` — تحرير/نشر parsing_rules + قراءة Engine Health.
- كل دخول أدمن: SSO + **2FA إلزامي** + audit log.

---

## 7. إضافات نموذج البيانات

### 7.1 على السيرفر (Postgres)
```sql
users(
  id PK, email TEXT UNIQUE NULL, google_id TEXT UNIQUE NULL,
  apple_id TEXT UNIQUE NULL, is_apple_relay_email BOOL,
  email_verified BOOL, country TEXT, created_at, last_login_at, status
)
sessions(
  id PK, user_id FK, refresh_token_hash, device_info, expires_at, revoked BOOL
)
otp_codes(
  id PK, email TEXT, code_hash, attempts INT, expires_at, consumed BOOL
)
aggregated_metrics(
  id PK, metric_key TEXT, dimension TEXT, value NUMERIC, day DATE
)               -- لا user_id مرتبط بمحتوى مالي
bank_rules(
  id PK, bank_key, locale, rules_json, version, published_at, is_active
)
admins(
  id PK, email, role, twofa_secret, created_at
)
audit_log(
  id PK, admin_id FK, action, target, meta_json, created_at
)
```

### 7.2 على الجهاز (إضافة لـ user_settings)
```sql
auth_state(
  user_id, auth_method,           -- google | apple | email
  access_token_ref, refresh_token_ref,   -- مراجع Keychain/Keystore
  last_synced_at
)
```
> ملاحظة: جداول transactions/budgets/goals... تبقى **on-device فقط** كما هي.

---

## 8. الأمان (Security)
- JWT موقّع (RS256)، access قصير + refresh دوّار.
- OTP: hashed at-rest، TTL 10د، ≤5 محاولات، rate-limit بالـ IP/البريد، 30ث بين الإرسالات.
- توكنات على الجهاز في Keychain/Keystore حصراً.
- TLS لكل الاتصالات؛ certificate pinning مستحسن.
- Admin: 2FA إلزامي + IP allowlist اختياري + audit log كامل.
- Metrics: تُرسل بدون PII؛ فصل المسارات (auth منفصل عن metrics) لتقليل الربط.

---

## 9. مقايضات وتخفيف (Trade-offs)

| المقايضة | التخفيف |
|---|---|
| الدخول الإجباري يزيد الاحتكاك ويؤخّر الـ Aha | Google one-tap كخيار أول + شاشة دخول واحدة بسيطة + لا نطلب أي بيانات إضافية |
| backend جديد = تكلفة + سطح هجوم | إبقاؤه أدنى (auth+metrics+rules فقط)، لا بيانات مالية = لا كارثة عند الاختراق |
| توتر مع رسالة «on-device» | تحديث الرسالة بدقة (القسم 2) والشفافية الكاملة |
| تكلفة إرسال إيميل OTP | تشجيع Google Sign-In كافتراضي؛ OTP fallback |

---

## 10. تحديثات مطلوبة على الوثائق الأخرى
1. **PRODUCT_SPEC.md §7 (الخصوصية):** استبدال «لا سيرفر إطلاقاً» بصياغة القسم 2 هنا.
2. **PRODUCT_SPEC.md §17:** إضافة backend المصادقة كاستثناء معرّف (auth + metrics + rules)، مع تأكيد عدم رفع بيانات مالية.
3. **WIREFRAMES.md:** إدراج Auth-1/Auth-2 بعد شاشة الخصوصية + إزالة كل الإيموجي واستبدالها بأيقونات مسمّاة.
4. **Data Model:** دمج جداول السيرفر (§7.1) كطبقة منفصلة عن الـ on-device DB.

---

## 11. أسئلة تحتاج إجابتك لاحقاً
1. مزوّد إرسال الإيميل لـ OTP (Amazon SES / Resend / Postmark)؟ ومنطقة الاستضافة (الرياض/الخليج للامتثال)؟
2. هل الأدمن يحتاج إدارة rules فعلياً في MVP، أم لوحة قراءة فقط أولاً؟
3. ~~حذف الحساب: soft delete أم فوري؟~~ ✅ **محسوم: Soft Delete 30 يوماً** للهوية على السيرفر (قابل للاستعادة بالدخول)، والبيانات المالية المحلية تُمسح فوراً. انظر PRODUCT_SPEC.md §24.2.
4. ~~هل نريد Apple Sign-In؟~~ ✅ **محسوم: نعم** — مضاف (إلزامي على iOS بسبب Guideline 4.8). انظر §4.2b.
