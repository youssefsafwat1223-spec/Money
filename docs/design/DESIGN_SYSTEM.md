# 🎨 نظام التصميم - المساعد المالي (Vibrant Fintech Design System)

هذا الملف عبارة عن "Skill/Reference" لأي مهندس أو ذكاء اصطناعي (AI) سيقوم بكتابة كود الـ **Flutter** الخاص بالتطبيق. يجب الرجوع لهذا الملف دائماً عند بناء أي واجهة جديدة لضمان تطابق التصميم والروح العامة للتطبيق.

## 1. الفلسفة العامة (Design Philosophy)
* **الهوية:** "Vibrant Fintech" - حيوي، شبابي، طاقة عالية، وموثوق كالبنوك.
* **الابتعاد عن:** المظهر الآلي المظلم (Cyberpunk / AI-generated)، والتصميم المعقد المزدحم.
* **التركيز على:** مساحات بيضاء/رمادية نظيفة جداً لتسهيل قراءة الأرقام، مع استخدام التدرجات الحيوية (Gradients) في المناطق العلوية (Headers) لضخ الطاقة.
* **اللمس (Tactile):** كل عنصر قابل للضغط يجب أن يتقلص قليلاً (Scale down) ليعطي إحساساً فيزيائياً ممتعاً.

---

## 2. الألوان الأساسية (Color Tokens)

يجب تعريف هذه الألوان في `ThemeData` أو كفئة `AppColors` في Flutter. التطبيق يدعم الوضعين الفاتح (Light) والداكن (Dark).

### ☀️ الوضع الفاتح (Light Mode)
* **Background (الخلفية العامة):** `#F8FAFC`
* **Surface (البطاقات):** `#FFFFFF`
* **Surface 2 (الخيارات / حقول الإدخال):** `#F1F5F9`
* **Primary (اللون الرئيسي):** `#7C3AED` (Royal Purple)
* **Primary Gradient:** `LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFFFF6B4A)], begin: Alignment.topRight, end: Alignment.bottomLeft)`
* **Accent (التمييز / التحفيز):** `#FF6B4A` (Sunset Coral)
* **Success (الإيجابي / الإيداع):** `#10B981` (Emerald Green)
* **Danger (السلبي / السحب):** `#EF4444` (Coral Red)
* **Text Main:** `#0F172A`
* **Text Light (رمادي):** `#64748B`
* **Borders:** `#E2E8F0`

### 🌙 الوضع الداكن (Dark Mode)
* **Background (الخلفية العامة):** `#0B0F19` (فحمي)
* **Surface (البطاقات):** `#131924` (فحمي داكن)
* **Surface 2 (الخيارات / حقول الإدخال):** `#1E2535`
* **Primary:** `#818CF8` (Amethyst Purple)
* **Primary Gradient:** `LinearGradient(colors: [Color(0xFF4F46E5), Color(0xFFFF7D66)])`
* **Accent (التمييز / التحفيز):** `#FF7D66` (Soft Sunset Coral)
* **Success:** `#34D399`
* **Text Main:** `#F8FAFC`
* **Text Light (رمادي):** `#8295A5`
* **Borders:** `#2A3347`

---

## 3. المكونات البرمجية الأساسية (Flutter Components)

### 🔘 الأزرار (Buttons)
* **Primary Button:** 
  - اللون: `Primary`
  - الانحناء (Border Radius): `16px`
  - الارتفاع: `56px`
  - الظل (Shadow): ظلال ملونة بلون الـ Primary بشفافية 30% `BoxShadow(color: primary.withOpacity(0.3), blurRadius: 24, offset: Offset(0, 8))`
  - **حركة الضغط (Tap):** استخدام `GestureDetector` أو `InkResponse` مع حركة `Scale` تصغر الزر بنسبة 3% عند الضغط.

### 📝 حقول الإدخال (Inputs)
* **الشكل العادي:** خلفية `Surface 2`، إطار (Border) بلون `Borders` العادي 1.5px.
* **الشكل عند التركيز (Focused):** 
  - إطار بلون `Primary`.
  - خلفية تتغير إلى `Surface` (أو لون أغمق في الدارك مود).
  - توهج ناعم (Glow) حول الحقل: `BoxShadow` بلون الـ Primary مع شفافية 10% وبدون إزاحة `offset: 0`.

### 📱 شريط التنقل السفلي (Bottom Navigation)
* **التصميم:** "الكبسولة الزجاجية العائمة" (Floating Glass Pill).
* **الموقع:** يرتفع عن أسفل الشاشة بمقدار `20px`، وهامش جانبي `20px`.
* **التأثير الزجاجي:** استخدام `BackdropFilter` مع `ImageFilter.blur(sigmaX: 20, sigmaY: 20)` في Flutter.
* **لون الخلفية:** أبيض بشفافية 85% للـ Light، وأسود/رمادي داكن بشفافية 85% للـ Dark.
* **الزر العائم (FAB):** مدمج كعنصر داخل الكبسولة (في المنتصف)، مربع بانحناء `18px`، ولون `Primary` مع ظل ملون.

### 🃏 البطاقات (Cards)
* الانحناء (Border Radius): عادةً `24px` أو `32px` للبطاقات الكبيرة (مثل الخزنة).
* الظل (Shadows): ناعمة جداً وطويلة `blurRadius: 32` وبشفافية لا تتعدى 5% لـ 15% (الظلال تكون أقوى في الـ Dark Mode).

---

## 4. الحركات والتأثيرات (Animations)
* **Staggered Fade-in:** عند دخول المستخدم لأي شاشة تحتوي على قائمة (List) أو خيارات (Options)، يجب أن تظهر العناصر تباعاً (مثلاً تأخير 100ms بين كل عنصر) مع حركة من الأسفل للأعلى (Translate Y).
* **Floating:** الأيقونات التوضيحية (الخزنة 3D، البرق، إلخ) يجب أن تطفو باستمرار باستخدام `AnimationController` يتحكم في الـ `Transform.translate` بمقدار 8 بكسل صعوداً ونزولاً كل 4 ثوانٍ.

---

## 5. الخطوط (Typography)
* **عائلة الخط:** `IBM Plex Sans Arabic` أو خطوط النظام (System UI) إذا كانت تعطي شكلاً عصرياً.
* **العناوين الكبيرة (Hero):** أوزان `Bold (700)`، مقاس `24-28`.
* **النصوص الفرعية (Subtitles):** أوزان `Regular (400)` أو `Medium (500)`، ومقاس `14-15`، مع ارتفاع سطر `1.6` لسهولة القراءة.
