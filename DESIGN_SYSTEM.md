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
* **Background (الخلفية العامة):** `#F4F5F7`
* **Surface (البطاقات):** `#FFFFFF`
* **Surface 2 (الخيارات / حقول الإدخال):** `#F8F9FA`
* **Primary (اللون الرئيسي):** `#8E24AA` (Deep Magenta)
* **Primary Gradient:** `LinearGradient(colors: [Color(0xFF4F00BC), Color(0xFF9B27B0)], begin: Alignment.topLeft, end: Alignment.bottomRight)`
* **Accent (التمييز / التحفيز):** `#FFD54F`
* **Success (الإيجابي / الإيداع):** `#00C853`
* **Danger (السلبي / السحب):** `#FF3D00`
* **Text Main:** `#1a1a1a`
* **Text Light (رمادي):** `#9AA0A6`
* **Borders:** `#E0E0E0`

### 🌙 الوضع الداكن (Dark Mode)
* **Background (الخلفية العامة):** `#0A0A0C` (أسود عميق)
* **Surface (البطاقات):** `#1C1C1E` (رمادي داكن جداً - Apple Style)
* **Surface 2 (الخيارات / حقول الإدخال):** `#2C2C2E`
* **Primary:** `#AB47BC` (أفتح قليلاً ليتناسب مع الظلام)
* **Primary Gradient:** `LinearGradient(colors: [Color(0xFF2A0066), Color(0xFF5E146E)])`
* **Success:** `#00E676`
* **Text Main:** `#FFFFFF`
* **Text Light (رمادي):** `#6E6E73`
* **Borders:** `#38383A`

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
