# مواصفات الباك اند الكاملة (Backend Spec — مالي)

> الحالة الحالية: MVP **on-device بالكامل** (DB محلية مشفّرة SQLCipher) + **Auth/Backup حالياً stub** بلا سيرفر حقيقي.
> هذا المستند: كل ما يلزم لإضافة backend/database system حقيقي.

---

## 0. القرار الأول (مفترق الطريق) — لازم تختاره

| | **A) On-device + Backend خفيف** (المعتمد حالياً) | **B) Server-backed** (DB على السيرفر) |
|---|---|---|
| البيانات المالية | تبقى على الجهاز؛ السيرفر يحفظ **blob مشفّر E2E فقط** لا يقرأه | تُخزَّن على السيرفر (يقدر يقرأها) |
| الخصوصية | ✅ أقوى ميزة تنافسية | ⚠️ تكسر وعد «بياناتك على جهازك» |
| المزامنة realtime عبر الأجهزة | محدودة (عبر backup/restore) | ✅ كاملة وفورية |
| web app / أدمن يشوف بيانات | ❌ | ✅ |
| الامتثال (PDPL) | أبسط (لا نقل بيانات حساسة) | أثقل (تخزين + تشفير + تراخيص محتملة) |
| التكلفة والتعقيد | أقل | أعلى |

**توصيتي: A** — يحافظ على تمايزنا (الخصوصية)، والباك اند يخدم **auth + backup مشفّر + مقاييس مجهولة + rules + أدمن** فقط. (تفاصيل التصميم موجودة أصلاً في `docs/specs/AUTH_AND_ADMIN_SPEC.md`.)
> لو عايز web app أو مزامنة فورية أو أدمن يشوف بيانات المستخدم → تحتاج B جزئياً، وساعتها لازم نعيد التفكير في وعد الخصوصية.

**باقي المستند مبني على المسار A** (مع إشارة لما يتغيّر في B).

---

## 1. مكوّنات الباك اند المطلوبة

### 1.1 Auth Service (مصادقة)
- **الغرض:** تسجيل/دخول Google/Apple/Email-OTP، إصدار JWT.
- **Endpoints:**
  - `POST /auth/google` (يتحقق من id_token من جوجل) → JWT
  - `POST /auth/apple` (يتحقق من identity_token من آبل) → JWT
  - `POST /auth/email/request` (يرسل OTP عبر SES)
  - `POST /auth/email/verify` (يتحقق من الكود) → JWT
  - `POST /auth/refresh` (تدوير refresh token)
  - `POST /auth/logout` · `DELETE /auth/account` (soft-delete 30 يوم)
- **Tables:** `users`, `sessions`, `otp_codes` (مفصّلة في AUTH_AND_ADMIN_SPEC §7.1).

### 1.2 Database (Postgres)
- **الغرض:** تخزين الهوية + الـ backup blobs + المقاييس + القواعد + الأدمن.
- **الجداول الأساسية:**
```
users(id, email, google_id, apple_id, is_apple_relay_email, email_verified,
      country, created_at, last_login_at, status, delete_scheduled_at)
sessions(id, user_id, refresh_token_hash, device_info, expires_at, revoked)
otp_codes(id, email, code_hash, attempts, expires_at, consumed)
backups(id, user_id, encrypted_blob, blob_version, size_bytes, updated_at, device_info)
aggregated_metrics(id, metric_key, dimension, value, day)   -- بلا هوية مالية
bank_rules(id, bank_key, locale, rules_json, version, published_at, is_active)
admins(id, email, role, twofa_secret, created_at)
audit_log(id, admin_id, action, target, meta_json, created_at)
```
> ملاحظة: **لا توجد جداول transactions/budgets/... على السيرفر** في المسار A. (تظهر فقط في المسار B.)

### 1.3 Encrypted Backup Storage
- **الغرض:** تخزين نسخة الـ backup المشفّرة E2E.
- **الخيار:** blob صغير في عمود `backups.encrypted_blob` (BYTEA)، أو ملف في **S3-compatible storage** (للأحجام الأكبر).
- **القاعدة الذهبية:** السيرفر **لا يملك المفتاح** ولا يقدر يفك التشفير. التشفير AES-256-GCM + مفتاح مشتقّ من passphrase (Argon2id) **على الجهاز قبل الرفع**.

### 1.4 Metrics Ingestion (مقاييس مجهولة)
- **الغرض:** أحداث مجهولة لتحسين المنتج (CODEX_HANDOFF §25.12).
- **Endpoint:** `POST /metrics/batch` (أحداث بلا PII: parse_success(bank_key), aha, crash...).
- **مهم:** بدون مبالغ/متاجر/بريد مرتبط بسلوك مالي. opt-out يُحترم.

### 1.5 Rules Config (قواعد التحليل عن بُعد)
- **الغرض:** تحديث `parsing_rules` لإضافة بنوك دون تحديث متجر.
- **Endpoint:** `GET /rules?locale=ar-SA&version=N` → أحدث القواعد.
- التطبيق يجلبها دورياً ويخزّنها محلياً في جدول `parsing_rules`.

### 1.6 Admin Dashboard (ويب)
- **الغرض:** لوحة مقاييس مجمّعة مجهولة + إدارة rules (AUTH_AND_ADMIN_SPEC §6).
- **Tech:** Next.js/React + RBAC + 2FA إلزامي + audit log.
- **يقرأ مجاميع فقط** — لا يرى مستخدماً فرداً ولا بيانات مالية.

### 1.7 Email (OTP) — Amazon SES
- لإرسال أكواد الـ OTP. (بديل: Resend/Postmark.)

---

## 2. الـ Stack المقترح
| الطبقة | الاختيار | البديل |
|---|---|---|
| Backend API | **NestJS (Node/TS)** | Go (Fiber) · Laravel |
| Database | **PostgreSQL** | — |
| Cache/Queue | **Redis** (OTP TTL + rate-limit) | — |
| Backup storage | Postgres BYTEA أو **S3-compatible** | — |
| Email | **Amazon SES** | Resend |
| Admin web | **Next.js** | React + Vite |
| Auth tokens | **JWT RS256** + refresh دوّار | — |
| IaC | Terraform | — |
| CI/CD | GitHub Actions | — |
| Monitoring | Sentry + Grafana/CloudWatch | — |

---

## 3. الأمان (Security)
- **JWT RS256** موقّع، access قصير (15د) + refresh دوّار (rotation).
- **OTP:** hashed (Argon2/bcrypt)، TTL 10د، ≤5 محاولات، rate-limit بالـ IP/البريد.
- **Backup E2E:** السيرفر يخزّن blob فقط؛ لا يملك المفتاح.
- **TLS** لكل الاتصالات + **certificate pinning** في التطبيق.
- **Rate limiting** + **WAF** على كل الـ endpoints.
- **Secrets** في Secrets Manager (مش في الكود).
- **Admin:** 2FA إلزامي + IP allowlist + audit log كامل.
- **توكنات الجهاز:** في Keychain/Keystore (موجود — flutter_secure_storage).

---

## 4. البنية التحتية والاستضافة
- **المنطقة:** السعودية/الخليج (مثل **AWS me-south-1 البحرين** أو سحابة محلية سعودية) — مهم لـ **data residency / PDPL**.
- **بيئات:** dev / staging / prod منفصلة.
- **Containers:** Docker + (ECS/Fargate أو Kubernetes أو VPS بسيط في البداية).
- **Backups للـ DB** (Postgres) + monitoring + alerting.

---

## 5. الامتثال (Compliance)
- **PDPL السعودي:** data residency محلي، موافقة صريحة، حق الحذف (soft-delete 30 يوم)، DPA مع المزوّدين.
- **سياسة خصوصية + شروط** بالعربية محدّثة لتعكس الـ backend.
- **App Store/Google Play:** حذف الحساب داخل التطبيق (موجود) + إفصاحات البيانات.

---

## 6. ما الذي يتغيّر في تطبيق Flutter (استبدال الـ stubs)
| الحالي (stub) | يُستبدل بـ |
|---|---|
| `StubAuthService` | `ApiAuthService`: google_sign_in + sign_in_with_apple + dio لاستدعاء `/auth/*` + تخزين JWT |
| `StubBackupService` | `EncryptedBackupService`: cryptography (Argon2id + AES-256-GCM) + رفع/تنزيل blob عبر `/backup` |
| (لا يوجد) | `MetricsClient` (POST /metrics/batch) + `RulesClient` (GET /rules) |
- نضيف `dio` + base API client + interceptor للتوكن + إعادة المحاولة.
- الواجهات (AuthService/BackupService) **موجودة بالفعل** — بس نبدّل التنفيذ. (تصميم نظيف يسهّل ده.)

---

## 7. خطوات التنفيذ (Phased)
1. **Phase B1 — Auth حقيقي:** Postgres + users/sessions/otp + Google/Apple verify + SES OTP + JWT. استبدال StubAuthService.
2. **Phase B2 — Backup مشفّر:** تشفير E2E في التطبيق + endpoint رفع/تنزيل blob + restore على جهاز جديد.
3. **Phase B3 — Metrics + Rules:** ingestion مجهول + rules config عن بُعد.
4. **Phase B4 — Admin web:** لوحة مقاييس + إدارة rules + RBAC/2FA.

---

## 8. التكلفة التقديرية (بداية صغيرة)
- VPS/Fargate صغير + Postgres مُدار + Redis + SES → **عشرات الدولارات/شهر** في البداية، تتدرّج مع المستخدمين.
- SES رخيص جداً (آلاف الإيميلات بدولارات قليلة).

---

## 9. ملخّص القرار
- **المسار A (موصى به):** backend خفيف يخدم auth + backup E2E + metrics + rules + admin. **البيانات المالية تفضل على الجهاز.** يحافظ على تمايزنا ويبسّط الامتثال.
- **المسار B:** تخزين البيانات على السيرفر — فقط لو محتاج web/مزامنة فورية/أدمن يشوف بيانات، وبتكلفة خصوصية وامتثال أعلى.

> أغلب التصميم التفصيلي للمسار A **موثّق بالفعل** في `docs/specs/AUTH_AND_ADMIN_SPEC.md` — هذا المستند يجمّع الصورة الكاملة.
