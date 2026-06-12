# الهوية ونظام التصميم (Brand Strategy & Design System)

> Arabic-first · RTL · بدون إيموجي · Dark + Light. اسم التطبيق placeholder مؤقت (لا يحجب التصميم).
> الخطوط: **IBM Plex Sans Arabic** · الأيقونات: **Lucide** · الخزنة: **2D premium بحركة خفيفة** (لا 3D).
> الجمهور والشعور: **رفيق مالي ذكي ومدرّب ادخار — ليس تطبيق بنك ولا برنامج محاسبة.**

---

# الجزء الأول: استراتيجية الهوية (Brand Strategy)

## 1. شخصية العلامة (Brand Personality)
خمس سمات تحكم كل قرار تصميمي ونصّي:

| السمة | تعني | لا تعني |
|---|---|---|
| **مشجّع (Encouraging)** | يحتفل بالتقدّم، يدفعك للأمام بلطف | يلوم، يخوّف، يضغط |
| **هادئ-واثق (Calm-Confident)** | بساطة، وضوح، طمأنينة | ازدحام، إنذارات، توتر |
| **ذكي بلا تعالٍ (Smart, not preachy)** | رؤى مفيدة بكلمات بسيطة | مصطلحات مالية، محاضرات |
| **دافئ (Warm)** | إنساني، قريب، يخاطبك بـ«أنت» | بارد، رسمي، مؤسسي |
| **Premium-بسيط** | جودة، مساحات، تفاصيل مدروسة | رخيص، مزدحم، قالب AI |

## 2. النموذج الأصلي (Brand Archetype)
- **الأساسي: المدرّب / المرشد (The Coach / Mentor)** — مزيج من *Sage* (حكمة ورؤى) و*Caregiver* (دعم وأمان). يقف بجانبك، يفهم أرقامك، ويوجّهك بلطف نحو هدفك.
- **لمسة ثانوية: الساحر (The Magician)** — التحوّل السحري: من فوضى رسائل البنك → وضوح وإحساس بالسيطرة. «حوّلنا الفوضى إلى لعبة.»
- **ما لسنا عليه:** *Ruler/Banker* (سلطة/مؤسسة باردة) ولا *Accountant* (جداول وأرقام جافة).

## 3. نبرة الصوت (Tone of Voice)
**المبادئ:** عربي مبسّط دافئ · مخاطبة مباشرة بـ«أنت» · جُمل قصيرة · احتفاء لا لوم · صفر مصطلحات · صفر إيموجي.

**افعل ↔ لا تفعل (أمثلة):**
| ✅ نقولها | ❌ لا نقولها |
|---|---|
| «وفّرت أكثر من الشهر اللي طاف. استمر!» | «تحليل الإنفاق: انخفاض 18% في فئة المطاعم» |
| «اقتربت من حد ميزانية المطاعم — باقي 15 ريال» | «تحذير: تجاوز وشيك للحد المخصص» |
| «ما قدرنا نقرأ الرسالة — عبّيها بنفسك بسرعة» | «خطأ: فشل تحليل الرسالة (Parse Error)» |
| «خزنتك امتلأت! حقّقت هدفك» | «تهانينا، تم بلوغ 100% من القيمة المستهدفة» |

**قواعد:**
- العناوين فعل/إحساس، لا تصنيفات بنكية.
- لا تأنيب عند التجاوز — نقدّم خطوة عملية بدلاً منه.
- الأرقام تُقدَّم بسياق («باقي…»، «أقل بـ…») لا مجرّدة.

## 4. الأهداف العاطفية (Emotional Goals)
ما نريد أن يشعر به المستخدم في كل لحظة:
1. **مسيطر (In control):** «أعرف أين تذهب فلوسي دون مجهود.»
2. **فخور (Proud):** «أنا أتقدّم — streak، خزنة تمتلئ، شارات.»
3. **آمن (Safe):** «بياناتي على جهازي، وأنا متحكم.»
4. **محفَّز يومياً (Motivated):** «أرجع كل يوم لأن الأمر ممتع، مش واجب.»
5. **هادئ (Calm):** «التطبيق يطمئنّي، لا يوتّرني.»

> الشعور الجامع: **«التوفير أصبح لعبة يومية ممتعة وآمنة.»**

## 5. المبادئ البصرية (Visual Principles)
1. **العاطفة قبل البيانات** — كل شاشة تبدأ بشعور/تحفيز ثم تفصيل.
2. **بؤرة واحدة لكل شاشة** — عنصر بطل واضح + إجراء أساسي واحد.
3. **هدوء premium** — مساحات بيضاء سخيّة، عناصر أقل، تباين مدروس.
4. **عمق ناعم** — طبقات surfaces وظلال خفيفة بدل خطوط ثقيلة.
5. **حركة هادفة** — تكافئ وتوجّه، لا تزخرف. تحترم reduce-motion.
6. **الخزنة هي البطل البصري** — عنصر الهوية المركزي، حاضر في Dashboard/Goals/الاحتفالات.
7. **Arabic-first / RTL أصيل** — لا انعكاس متأخّر؛ أرقام tabular.
8. **بدون إيموجي** — كل رمز أيقونة Lucide متّسقة.

---

# الجزء الثاني: نظام التصميم (Design System)

## 6. الألوان (Color Tokens)
> tokens دلالية (semantic) تشتق من الخام. القيم لوضعَي Dark (أساسي) + Light.

### 6.1 الخام (Brand / Raw)
```
brand-purple       #7C3AED   (اللون الأساسي للأرجواني)
brand-coral        #FF6B4A   (اللون المساعد المرجاني - التوفير/النمو)
```

### 6.2 Dark (الأساسي)
```
--bg               #0B0F19
--surface          #131924
--surface-2        #1E2535
--surface-3        #2A3347   (عناصر مرتفعة/inputs)
--hairline         #2A3347   (حدود خفيفة)
--primary          #818CF8
--primary-press    #6366F1
--primary-tint     #1E2535   (خلفية خفيفة)
--accent-gold      #FF7D66
--danger           #F87171
--danger-tint      #2B1519
--warning          #F59E0B
--warning-tint     #2D2012
--info             #38BDF8
--text-primary     #F8FAFC
--text-secondary   #8295A5
--text-muted       #4F5A6E
--on-primary       #0B0F19
```

### 6.3 Light
```
--bg               #F8FAFC
--surface          #FFFFFF
--surface-2        #F1F5F9
--surface-3        #E2E8F0
--hairline         #E2E8F0
--primary          #7C3AED
--primary-press    #5B21B6
--primary-tint     #F1F5F9
--accent-gold      #FF6B4A
--danger           #EF4444
--danger-tint      #FEE2E2
--warning          #D97706
--warning-tint     #FEF3C7
--info             #0EA5E9
--text-primary     #0F172A
--text-secondary   #475569
--text-muted       #94A3B8
--on-primary       #FFFFFF
```

### 6.4 ألوان حالات الميزانية (Budget States)
```
safe     = --primary    (≤ 79%)
warning  = --warning     (80–99%)
over     = --danger      (≥ 100%)
```

### 6.5 ألوان التصنيفات (Category Accents)
لكل تصنيف لون هادئ (يُستخدم خلف أيقونته). أمثلة (نفس القيم تقريباً في الثيمين مع ضبط السطوع):
```
مطاعم #FF7A59 · بقالة #2FD27A · مواصلات #4DA3FF · وقود #F2C14E
فواتير #9B8CFF · تسوق #FF6FA5 · صحة #36C5CE · تعليم #5B8DEF
ترفيه #C66BFF · اشتراكات #7A86FF · تحويلات #8A94A3 · سحب نقدي #B0B8C4
سفر #38B6FF · هدايا #FF8FB1 · أطفال #FFC24D · منزل #57C99A
كافيهات #C89B6B · صيانة #9AA4B2 · دخل #2FD27A · أخرى #8A94A3
```

## 7. الطباعة (Typography) — IBM Plex Sans Arabic
**الأوزان:** Light 300 · Regular 400 · Medium 500 · SemiBold 600 · Bold 700.
**قاعدة إلزامية:** المبالغ والأرقام المالية = **Tabular figures** (أرقام بعرض ثابت).
**المحاذاة الافتراضية:** يمين (RTL).

| Style | الحجم/السطر (px) | الوزن | الاستخدام |
|---|---|---|---|
| Amount-Hero | 40 / 44 | Bold (tabular) | الرقم البطل (وفّرت/المبلغ) |
| Display | 34 / 40 | Bold | عناوين شاشات كبيرة |
| Title-1 | 28 / 34 | SemiBold | عناوين رئيسية |
| Title-2 | 22 / 28 | SemiBold | عناوين أقسام |
| Headline | 18 / 24 | SemiBold | بطاقات/عناصر بارزة |
| Body | 16 / 24 | Regular | النص الأساسي |
| Body-Strong | 16 / 24 | Medium | تأكيد ضمن النص |
| Callout | 15 / 22 | Regular | نص ثانوي |
| Subhead | 14 / 20 | Medium | عناوين صفوف/labels |
| Footnote | 13 / 18 | Regular | ملاحظات |
| Caption | 12 / 16 | Medium | وسوم/تواريخ صغيرة |

## 8. المسافات والشبكة (Spacing & Grid)
**القاعدة: 4pt.** سلّم المسافات:
```
space-1 = 4    space-2 = 8    space-3 = 12   space-4 = 16
space-5 = 20   space-6 = 24   space-7 = 32   space-8 = 40
space-9 = 48   space-10 = 64
```
- **هوامش الشاشة (gutter):** 20px جانبي.
- **مسافة بين البطاقات:** 12–16px.
- **حشو البطاقة (padding):** 16–20px.
- **جهاز مرجعي:** 390×844؛ تصميم مرن (min 360 → max 430).

## 9. الزوايا والارتفاع (Radius & Elevation)
```
radius-sm   8     (chips/inputs صغيرة)
radius-md   12    (أزرار/inputs)
radius-lg   16    (بطاقات ثانوية)
radius-card 20    (البطاقات الرئيسية)
radius-xl   28    (bottom sheets أعلى)
radius-pill 999   (streak pill/فلاتر)
```
**الظلال (Light فقط — Dark يعتمد surfaces + توهج خفيف):**
```
shadow-1: 0 1 2 rgba(16,17,22,.06)
shadow-2: 0 4 12 rgba(16,17,22,.08)
shadow-3: 0 12 32 rgba(16,17,22,.12)   (sheets/modals)
Dark glow (اختياري للبطل): 0 0 24 rgba(47,210,122,.18)
```

## 10. الأيقونات (Iconography) — Lucide
- **الأسلوب:** outline، stroke **1.75px** (عند 24)، أطراف مدوّرة.
- **المقاسات:** 16 / 20 / 24 (افتراضي) / 28 (بارزة).
- **اللون:** يرث `currentColor` (text-secondary افتراضي، primary عند التفعيل).
- **إلزامي:** كل أيقونة لها **accessibility label** نصي (لأننا بلا إيموجي) لـ VoiceOver/TalkBack.
- **مرايا RTL:** الأيقونات الاتجاهية تُعكَس (chevron-right ↔ chevron-left، أسهم، send).

**تعيين التصنيفات → Lucide:**
```
مطاعم utensils · بقالة shopping-basket · مواصلات bus · وقود fuel
فواتير file-text · تسوق shopping-bag · صحة heart-pulse · تعليم graduation-cap
ترفيه gamepad-2 · اشتراكات repeat · تحويلات arrow-left-right · سحب نقدي banknote
سفر plane · هدايا gift · أطفال baby · منزل home
كافيهات coffee · صيانة wrench · دخل trending-up · أخرى ellipsis
```
**أيقونات نظام شائعة:** streak `flame` · هدف `target` · رؤية `lightbulb` · تنبيه `alert-triangle` · خصوصية/قفل `lock` · شارة `medal` · إعدادات `settings` · بحث `search` · إضافة `plus` · تأكيد `check` · حذف `trash-2` · backup `cloud` · مستوى `bar-chart-2`.

## 11. الخزنة 2D (The Vault) — عنصر الهوية
- **التنفيذ:** illustration متجهي (SVG) + حركة خفيفة عبر **Rive** أو **Lottie** (خفيف الوزن، < 200KB).
- **التصميم:** خزنة آمنة محايدة ثقافياً (لا piggy/كحول/رموز غير مناسبة)، خط نظيف premium، باب دائري + مقبض، تتراكم بداخلها **عملات ذهبية** (`accent-gold`).
- **الخاصية:** `progress` (0–100) تتحكّم بمستوى امتلاء العملات.
- **الحالات:**
  - 0%: فارغة، باب مفتوح قليلاً، دعوة «ابدأ هدفك».
  - 1–99%: تمتلئ تدريجياً بالعملات حسب النسبة.
  - 100%: ممتلئة + **توهّج ذهبي خفيف** + احتفال قصير.
- **الحركة:**
  - idle: «تنفّس» خفيف جداً (scale 1→1.01، 3s).
  - عند مساهمة: سقوط عملة + رنّة بصرية قصيرة (250ms).
  - عند 100%: shimmer ذهبي لمرة واحدة.
- **النِسب من الأصل:** المربع 1:1، تظهر بثلاثة مقاسات (S في بطاقات الأهداف ~96px، M في Dashboard ~180px، L في Goal Details ~260px).
- **احتياطي:** نسخة static SVG لكل حالة (0/25/50/75/100) تُستخدم إن تعذّرت الحركة أو عند reduce-motion.

## 12. المكوّنات الأساسية (Core Components)

**Button**
- المقاسات: lg (h=52, radius-md, Headline) · md (h=44) · sm (h=36).
- الأنواع: `primary` (تعبئة خضراء، نص on-primary) · `secondary` (surface-2 + hairline) · `ghost` (شفاف، نص primary) · `danger` (نص/حد danger، تعبئة عند التأكيد).
- الحالات: default/hover(press -press)/disabled(40% opacity)/loading(spinner داخلي).

**Card** — surface, radius-card, padding 16–20, hairline في Dark / shadow-1 في Light.

**Transaction Row** — [أيقونة تصنيف دائرة 40px بلون التصنيف tint] + (اسم المتجر Body-Strong / تصنيف·وقت Subhead muted) + مبلغ (Amount، أحمر للخصم / أخضر للدخل) + وسم «غير مؤكدة» إن وُجد.

**Category Chip** — pill, أيقونة 16 + اسم Caption، حالة مختارة = primary-tint + نص primary.

**Budget Bar** — track surface-3 h=10 radius-pill، fill بلون الحالة (safe/warning/over)، نص النسبة Caption.

**Goal/Vault Card** — الخزنة (S/M) + اسم الهدف Headline + نسبة + «X من Y».

**Streak Pill** — pill, أيقونة flame + «17 يوم» Subhead، حد gold خفيف.

**XP / Level Bar** — شريط رفيع h=6 + نص المستوى Caption + XP حالي/التالي.

**Badge** — دائرة 64px، مفتوحة (ملوّنة + gold ring) / مقفولة (surface-2 + lock رمادي).

**Bottom Sheet (Confirm/Backup)** — radius-xl أعلى، handle 36×4، padding 20، إجراء أساسي lg أسفل.

**Bottom Nav** — 5 عناصر (الرئيسية/العمليات/الأهداف/الإنجازات/حسابي)، أيقونة 24 + Caption، نشط = primary، FAB إضافة في الوسط (Dashboard/العمليات).

**Inputs** — h=52, surface-3, radius-md, hairline؛ تركيز = حد primary. حقل OTP = 6 خانات مربّعة 48×56.

**Empty State** — أيقونة كبيرة muted + عنوان Headline + سطر Callout + زر primary.

**Toast / Celebration** — Toast أعلى (نجاح أخضر/خطأ أحمر، 3s). Celebration overlay (Rive، الخزنة/الشارة) يُغلق تلقائياً + زر.

## 13. الحركة (Motion)
```
duration-fast   120ms   (ضغط أزرار/توست)
duration-base   200ms   (انتقالات/أوراق)
duration-slow   320ms   (احتفالات/خزنة)
easing-standard cubic-bezier(.2,.8,.2,1)
easing-in       cubic-bezier(.4,0,1,1)
```
- انتقالات الشاشات: slide RTL (الجديد يدخل من اليسار، الرجوع لليمين).
- **reduce-motion:** إلغاء التنفّس/الـshimmer، استبدال الاحتفال بظهور ثابت + toast.

## 14. إمكانية الوصول (Accessibility)
- تباين نص أساسي/خلفية ≥ **WCAG AA** (4.5:1) في الثيمين.
- دعم **Dynamic Type** حتى +٢ خطوات دون كسر التخطيط.
- **labels لكل أيقونة** (إلزامي — لا إيموجي).
- مناطق لمس ≥ 44×44.
- لا نعتمد على اللون وحده لحالات الميزانية — نضيف نص نسبة + أيقونة.

## 15. خريطة Tokens → Figma
1. أنشئ **Variables Collections**: `color` (modes: Dark/Light)، `number` (spacing/radius)، `string` (type styles).
2. كل مكوّن في القسم 12 = **Component** مع variants (size/state).
3. الخزنة = component بخاصية `progress` (أو 5 variants للحالات + نسخة static).
4. فعّل **RTL** على الإطار، وافحص مرايا الأيقونات.
5. أنشئ **Text Styles** من جدول القسم 7 (مع تفعيل tabular figures للأرقام).

---

## التالي
بعد اعتماد هذا الأساس → نبني **النموذج التفاعلي hi-fi** (HTML/CSS، RTL، الثيمين)، بدءاً من **Onboarding + Auth** كما اتُّفق.
