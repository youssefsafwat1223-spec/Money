# MAC_HANDOFF — تسليم المشروع للماك (Mali / money_companion)

> هذا الملف موجّه لـ Claude Code أو Codex العامل على جهاز **Mac**.
> اقرأه بالكامل قبل أي تعديل. يشرح: حالة المشروع، ما تم إنجازه حرفياً، وما هو
> الناقص بالضبط لإكمال بناء iOS IPA مع ميزة الـ Shortcut والـ Share Extension.
>
> اللغة هنا عربي + إنجليزي تقني. كل المسارات نسبية من جذر الريبو
> `money/` ما لم يُذكر غير ذلك.

---

## 0. ملخّص في 30 ثانية (TL;DR)

- تطبيق Flutter كامل وشغّال (`app/`)، تحليله نظيف و **63 اختبار ناجح**.
- بناء iOS على Codemagic **يفشل حالياً** بإيرور واحد:
  `Cannot find 'SharedCaptureStore' in scope` لأن ملف Swift غير مضاف لتارجت Runner.
- ميزة "Post Bank Status" (App Intent) و الـ Share Extension **مكتوبة بالكامل
  ككود Swift** لكن **تارجتاتها غير موجودة في مشروع Xcode** → لن تظهر في الـ IPA.
- **كل أكواد Swift وملفات الـ entitlements/plist موجودة وجاهزة** — الناقص هو
  **ربطها داخل `project.pbxproj`** (إنشاء التارجتات + إضافة الملفات للتارجت).
- على الماك ده شغل دقائق في Xcode (المعالج بيعمله أوتوماتيك). تفاصيل أسفل.

---

## 1. بنية المشروع

```
money/                         ← جذر الريبو (هنا codemagic.yaml و README.md)
├── codemagic.yaml             ← إعداد CI (تم، مدفوع لـ GitHub)
├── README.md                  ← دليل Codemagic (موجود لكن UNTRACKED — راجع §8)
├── MAC_HANDOFF.md             ← هذا الملف
├── PRODUCT_SPEC.md, BUILD_PLAN.md, ... (توثيق المنتج)
└── app/                       ← تطبيق Flutter
    ├── pubspec.yaml
    ├── lib/                   ← كود Dart (engine/ domain/ data/ features/ core/)
    ├── test/                  ← 63 اختبار
    └── ios/
        ├── Runner/            ← التطبيق الأساسي (target موجود)
        │   ├── AppDelegate.swift          ← يستدعي SharedCaptureStore ⚠️
        │   ├── SceneDelegate.swift
        │   ├── SharedCaptureStore.swift   ← ⚠️ مش مضاف لتارجت Runner
        │   ├── Runner.entitlements        ← App Group (مش مربوط في pbxproj)
        │   └── Info.plist
        ├── ShareBankMessage/   ← Share Extension (كود جاهز، target مفقود)
        │   ├── ShareViewController.swift
        │   ├── SharedCaptureStore.swift
        │   ├── Info.plist                 ← NSExtension مضبوط (share-services)
        │   └── ShareBankMessage.entitlements ← App Group
        ├── BankMessageShortcuts/  ← App Intents Extension (كود جاهز، target مفقود)
        │   ├── BankMessageShortcuts.swift ← PostBankStatusIntent + Provider
        │   └── SharedCaptureStore.swift
        │   └── (⚠️ لا يوجد Info.plist ولا .entitlements — لازم تتعمل)
        ├── SHORTCUT_SETUP.md   ← دليل إعداد الإكستنشنز خطوة بخطوة
        └── Runner.xcodeproj/project.pbxproj  ← ⚠️ فيه target واحد بس: Runner (+RunnerTests)
```

### معلومات أساسية
- **Bundle ID للتطبيق:** `com.example.moneyCompanion`
- **App Group (في الـ entitlements):** `group.com.example.money_companion.shared`
  - ملاحظة: عدم تطابق الـ underscore بين الـ bundle id و الـ App Group **مقصود ومقبول** —
    الـ App Group مستقل عن الـ bundle id. لا تُصلح أحدهما ليطابق الآخر.
- **Flutter:** `>=3.22.0` / Dart `>=3.4.0`
- **Method channel:** `money_companion/native_capture`

---

## 2. ما تم إنجازه حرفياً (DONE)

### تطبيق Flutter (كامل)
- ✅ معمارية نظيفة: `engine/` (Dart نقي) → `domain/` → `data/` → `features/`.
- ✅ Riverpod + go_router + RTL عربي + ثيم Navy(#0A2540)/Amber(#FFB300)/Success(#16A968).
- ✅ Parser/Categorizer/Normalizer + `CardNetworkDetector` + `BankSenderFilter`.
- ✅ قاعدة بيانات Drift + تشفير، ميزانيات، إنجازات/streak، إشعارات محلية.
- ✅ ميزة Cards (كشف شبكة البطاقة من SMS + قسم في الداشبورد).
- ✅ Onboarding كامل + شاشة Auth (Apple/Google/Email-OTP).
- ✅ Localization (عربي + إنجليزي) عبر ARB + `flutter gen-l10n`.
- ✅ `flutter analyze` نظيف، `flutter test` = **63/63 ناجح**.

### الباك إند (Supabase — Path A)
- ✅ `lib/core/backend/supabase_config.dart` يقرأ من `--dart-define`:
  ```dart
  static const url     = String.fromEnvironment('SUPABASE_URL');
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
  ```
- ✅ **Fallback stub mode**: لو المتغيرين فاضيين → التطبيق يشتغل بدون باك إند تلقائياً.

### كود iOS Capture (مكتوب بالكامل، ينقص الربط فقط)
- ✅ `AppDelegate.swift`: method channel فيه `consumePendingSharedInput` و
  `consumePendingSharedMessages` (يرجّع JSON array من الرسائل).
- ✅ 3 نسخ متطابقة من `SharedCaptureStore.swift` (Runner / ShareBankMessage /
  BankMessageShortcuts): طابور FIFO في App Group، `Payload{text, sender?}`،
  `enqueue/consumePendingPayloadsJSON/consumePendingText`، مع ترحيل مفتاح قديم.
- ✅ `BankMessageShortcuts.swift`: `PostBankStatusIntent` (العنوان "Post Bank Status"،
  `openAppWhenRun=true`، باراميتر `message` متعدد الأسطر + `sender` اختياري) +
  `AppShortcutsProvider` بالعبارات الصوتية.
- ✅ `ShareViewController.swift`: يستقبل نص مشارَك ويستدعي `enqueue`.
- ✅ `Runner.entitlements` و `ShareBankMessage.entitlements` فيهم App Group.
- ✅ `ShareBankMessage/Info.plist` مضبوط (`NSExtensionActivationSupportsText`).

### جانب Flutter للـ capture (تم)
- ✅ `NativeCaptureBridge.consumePendingSharedMessages()` يفك JSON ويرجّع
  `List<SharedCapturedMessage>`.
- ✅ `AppShell._consumeSharedInput()` يفرّغ الطابور عند فتح/استئناف التطبيق ويمرّر
  كل رسالة بـ `senderId` إلى `CapturedMessageProcessor.process(...)`.

### CI / توثيق
- ✅ `codemagic.yaml` (جذر الريبو، مدفوع — commit `4d59298`): workflowان —
  `ios-unsigned-sideload` و `ios-signed-release`، بـ Supabase dart-defines + stub fallback.
- ✅ `app/ios/SHORTCUT_SETUP.md` — دليل الإكستنشنز.

---

## 3. ما هو الناقص بالضبط (TODO على الماك)

### 🔴 (A) عاجل — يكسر البيلد: إضافة `SharedCaptureStore.swift` لتارجت Runner
الإيرور الحالي على Codemagic:
```
Cannot find 'SharedCaptureStore' in scope — AppDelegate.swift:38 / :40
```
السبب: `app/ios/Runner/SharedCaptureStore.swift` موجود على الديسك ومعمول له
commit، لكنه **غير مضاف لتارجت Runner** في `project.pbxproj` (تأكدنا: مذكور 0 مرة).
فالكومبايلر مش بيشوفه.

**الحل على الماك (الأسهل):**
1. `open app/ios/Runner.xcworkspace`.
2. في الـ navigator، اختر `SharedCaptureStore.swift` تحت مجموعة Runner.
3. في الـ File Inspector (يمين) → **Target Membership** → فعّل ✅ **Runner**.
4. (أو احذف الملف من المشروع وأعد إضافته: Add Files → Target = Runner.)

> ملاحظة: هذا وحده يكفي ليبني **التطبيق نفسه** (بدون الإكستنشنز) بنجاح.
> لو عايز تبني التطبيق فقط الآن للتجربة، اعمل (A) + (B) واطلع IPA.

### 🟠 (B) ربط App Group بتارجت Runner (مطلوب عشان الـ capture يشتغل فعلياً)
- `Runner.entitlements` موجود وفيه الـ App Group، لكن **غير مربوط**:
  `CODE_SIGN_ENTITLEMENTS` غير موجود في `project.pbxproj` (تأكدنا: NOT referenced).
- على الماك: Runner target → **Signing & Capabilities** → **+ Capability → App Groups**
  → فعّل `group.com.example.money_companion.shared`. Xcode سيضبط
  `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` تلقائياً.

### 🟡 (C) إنشاء تارجت الـ Share Extension: `ShareBankMessage`
- الكود + `Info.plist` + `.entitlements` **موجودين**، لكن **التارجت غير موجود** في pbxproj.
- على الماك: **File → New → Target → Share Extension**، الاسم `ShareBankMessage`.
  - احذف الملفات التي ولّدها المعالج، وأضف ملفات المجلد الموجودة
    (`ShareViewController.swift` + `SharedCaptureStore.swift`) بـ Target Membership =
    `ShareBankMessage`.
  - استخدم `Info.plist` و `ShareBankMessage.entitlements` الموجودين (أو طابقهما).
  - فعّل نفس App Group على هذا التارجت.

### 🟡 (D) إنشاء تارجت الـ App Intents Extension: `BankMessageShortcuts`
- الكود موجود، لكن **التارجت غير موجود** و **ينقص `Info.plist` و `.entitlements`**.
- على الماك: **File → New → Target → App Intents Extension** (أو Extension)، الاسم
  `BankMessageShortcuts`، Embed in Runner.
  - احذف العينة المولّدة وأضف `BankMessageShortcuts.swift` + `SharedCaptureStore.swift`
    بـ Target Membership = `BankMessageShortcuts`.
  - أنشئ `.entitlements` لهذا التارجت بنفس App Group (انسخ من
    `ShareBankMessage.entitlements`).
  - Deployment target ≥ **iOS 16.0** (الـ intent عليه `@available(iOS 16.0, *)`).

### 🟢 (E) التوقيع (Signing) — فقط للـ workflow الموقّع أو للتثبيت طويل المدى
- حساب Apple Developer Program، App Store Connect API key (ارفعه لـ Codemagic باسم
  `codemagic_asc_api_key`)، تسجيل الـ bundle ids للتارجتات الثلاثة + UDIDs للأجهزة.
- للـ unsigned/sideload: مش مطلوب وقت البناء (Sideloadly يعيد التوقيع بـ Apple ID مجاني).

### تفاصيل مرجعية كاملة لـ (C)/(D)/(E)
كلها مشروحة خطوة بخطوة في **`app/ios/SHORTCUT_SETUP.md`** — اتبعه حرفياً.

---

## 4. مسار البيانات (للفهم السريع)

```
Shortcut "Post Bank Status"  ┐                        ┌ Share sheet → Mali
 (message, sender?)          │                        │ (selected text)
   PostBankStatusIntent      │                        │  ShareViewController
        .perform()           └──► SharedCaptureStore.enqueue(text:sender:) ◄──┘
                                   (App Group UserDefaults — FIFO queue)
                                              │
              فتح/استئناف التطبيق → AppDelegate channel
              "consumePendingSharedMessages" → JSON array
                                              │
              NativeCaptureBridge.consumePendingSharedMessages()
                                              │
              AppShell._consumeSharedInput() → لكل رسالة:
              CapturedMessageProcessor.process(rawMessage, senderId)
              → ParserEngine + AddTransactionUseCase → شيت التأكيد
```

---

## 5. خطة التنفيذ المقترحة على الماك (بالترتيب)

1. **Clone + تشغيل المحلي:**
   ```bash
   cd app
   flutter pub get
   flutter gen-l10n
   flutter analyze        # يجب أن يكون نظيفاً
   flutter test           # يجب أن ينجح 63 اختبار
   ```
2. **افتح المشروع:** `open app/ios/Runner.xcworkspace` (مش .xcodeproj — لازم workspace
   بسبب CocoaPods/SPM).
3. نفّذ **(A)** ثم **(B)** → جرّب: `cd app && flutter build ios --release --no-codesign`.
   لو نجح، التطبيق سليم.
4. نفّذ **(C)** و **(D)** حسب `SHORTCUT_SETUP.md`.
5. فعّل App Group على التارجتات الثلاثة، واضبط التوقيع **(E)** لو هتعمل signed.
6. **commit** كل تعديلات `project.pbxproj` + أي `Info.plist`/`.entitlements` جديدة
   لـ `BankMessageShortcuts`، و **push** — عشان Codemagic يبني النسخة الكاملة.
7. أعد تشغيل Codemagic workflow (أو ابنِ محلياً على الماك مباشرة).

---

## 6. إعداد Codemagic (للرجوع)
- `codemagic.yaml` في جذر الريبو، workflowان:
  - `ios-unsigned-sideload` → IPA غير موقّع للـ Sideloadly/iLoader (لا يحتاج Apple Dev).
  - `ios-signed-release` → IPA موقّع (يحتاج Apple Dev + ASC API key).
- متغيرات Supabase: ضعها في مجموعة بيئة اسمها `supabase` داخل Codemagic
  (`SUPABASE_URL`, `SUPABASE_ANON_KEY`). بدونها → stub mode.
- الآن بعد إضافة التارجتات على الماك، أعد البناء ليطلع IPA كامل بالشورتكت.

> تنبيه: الآن الماك متاح، **يُفضّل البناء محلياً على الماك** أولاً للتجربة السريعة،
> ثم استخدام Codemagic للنسخ الموزّعة.

---

## 7. أوامر تحقق سريعة (للتأكد من الحالة)
```bash
# هل SharedCaptureStore مضاف لتارجت Runner؟ (المفروض > 0 بعد الإصلاح)
grep -c "SharedCaptureStore" app/ios/Runner.xcodeproj/project.pbxproj

# هل التارجتات الجديدة اتعملت؟ (المفروض تلاقيها بعد C/D)
grep -E "PBXNativeTarget \"(BankMessageShortcuts|ShareBankMessage)\"" \
  app/ios/Runner.xcodeproj/project.pbxproj

# هل App Group مربوط؟
grep -n "CODE_SIGN_ENTITLEMENTS" app/ios/Runner.xcodeproj/project.pbxproj
```

---

## 8. ملاحظات Git
- آخر commit: `4d59298 Add Codemagic CI config for iOS IPA builds` (مدفوع لـ main).
- **`money/README.md` غير متتبّع (untracked)** — لو عايز توثيق Codemagic داخل الريبو،
  اعمله commit:
  ```bash
  git add README.md && git commit -m "Add Codemagic/sideload README"
  ```
- الفرع: `main`. الريموت: `github.com/youssefsafwat1223-spec/Money.git`.

---

## 9. مزالق معروفة (Gotchas)
- **النسخ الثلاث من `SharedCaptureStore.swift` يجب أن تظل متطابقة** — تعديل واحدة يستلزم
  تعديل الثلاثة (Swift لا يشارك المصدر بين التارجتات).
- iOS **لا يقرأ SMS تلقائياً** — الـ Share Extension + الـ App Intent هما الطريق المدعوم.
  للأتمتة: Personal Automation في تطبيق Shortcuts (مشروح في `SHORTCUT_SETUP.md`).
- `flutter_secure_storage` و `sign_in_with_apple` لا يدعمان SPM — تحذير غير قاتل، استمر
  بـ CocoaPods (`pod install` يعمل تلقائياً).
- Apple ID مجاني عبر Sideloadly = صلاحية **7 أيام** (تنتهي ويُعاد التثبيت). المدفوع = سنة.
- على Windows لا يمكن بناء iOS — الآن الماك متاح فالمشكلة انتهت.
