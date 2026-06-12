# تقرير تقوية الواجهة والتصميم (UI/UX Upgrade Report)

> الهدف: نقل «مالي» من تطبيق نظيف وشغّال → تطبيق **premium بإحساس قوي** ينافس Revolut/Monzo/SAY بصرياً.
> الجمهور: Codex (للتنفيذ) + المالك (للقرار). المرجع: DESIGN_SYSTEM.md (Vibrant Fintech) + الكود الحالي.

---

## 1. مراجعة صريحة لحالتنا الحالية

**نقاط القوة (موجودة):**
- هوية واضحة (لوجو «مالي» + بنفسجي/ذهبي + Vibrant Fintech).
- بنية شاشات كاملة + RTL + IBM Plex Arabic + Lucide + بدون إيموجي.
- Dashboard تحفيزي (تحية/streak/وفّرت/خزنة/تصنيفات/آخر العمليات).

**نقاط الضعف البصرية (الفجوة عن التطبيقات القوية):**
1. **صفر رسوم بيانية حقيقية** — عندنا progress bars فقط. التطبيقات القوية مبنية على charts (trends، donut، sparklines).
2. **صفر حركة (motion)** — كل شيء static. لا عدّادات أرقام متحركة، لا transitions، لا haptics، لا احتفالات غنية.
3. **Loading = spinner** — التطبيقات القوية تستخدم **skeleton loaders** (shimmer).
4. **الخزنة 2D بسيطة** — رمز الهوية لكنه غير مبهر بعد.
5. **لا drill-down** — ما تقدرش تضغط على تصنيف تشوف تفاصيله/اتجاهه عبر الزمن.
6. **لا بحث/فلترة متقدّمة** في العمليات.
7. **Empty/Error states عامة** — نص + أيقونة، بدون رسوم توضيحية أو شخصية.
8. **الإعدادات/القوائم** — ListTiles افتراضية (وتحذيرات invisible ink).
9. **التفاصيل الدقيقة** — ظلال/عمق/تباعد غير متّسق تماماً عبر الشاشات.

> الخلاصة: التطبيق **وظيفياً ممتاز** لكنه بصرياً **"good" مش "wow"**. الفرق بين الاتنين = motion + charts + depth + micro-interactions.

---

## 2. ماذا تفعل التطبيقات القوية (Patterns نتعلّمها)

| التطبيق | ما يميّزه بصرياً |
|---|---|
| **Revolut** | عدّادات أرقام متحركة · رسوم بيانية نظيفة · انتقالات سلسة · بطاقات بعمق · haptics |
| **Monzo** | ألوان جريئة لكل تصنيف · timeline للعمليات بأيقونات تجار · «Pots» (أهداف) ممتعة |
| **Emma / Cleo** | شخصية ودودة · insights نصية ذكية · رسوم spending بسيطة · onboarding ممتع |
| **Wallet (BudgetBakers)** | charts غنية (donut/trend) · drill-down للتصنيفات · تقارير قوية |
| **SAY (منافسنا)** | streak · widgets · voice · بساطة |
| **Apple Wallet/Fitness** | عمق · حلقات تقدّم · احتفالات · رُقيّ بصري |

**الـ 6 عناصر اللي بتخلّي التطبيق "قوي":**
1. **Motion هادف** (أرقام متحركة، staggered entrance، hero transitions).
2. **Data viz جميل** (trend line، donut، sparklines، heatmap).
3. **Micro-interactions** (haptics، ضغط لمسي، ripple مدروس).
4. **Skeleton loaders** بدل spinners.
5. **Depth** (ظلال ناعمة، glass، gradient mesh، grain خفيف).
6. **Celebrations** (confetti/Rive عند الإنجاز).

---

## 3. تحليل الفجوات + التحسينات حسب المنطقة

### 3.1 Dashboard ⭐ (الأولوية القصوى — أكثر شاشة تُرى)
**ناقص:**
- **رسم اتجاه الصرف** (آخر 7/30 يوم) — sparkline أو bar chart صغير في الـ header.
- **عدّاد رقم متحرك** للـ«وفّرت»/«الصرف» (count-up animation).
- **Donut chart** للتصنيفات بدل/بجانب الـ bars.
- **بطاقة Insight ذكية** بنص متغيّر («أنفقت أقل 18% على المطاعم 👏» → بدون إيموجي: أيقونة + نص).
- **ضغط على تصنيف** → شاشة تفاصيل التصنيف.

### 3.2 Transactions
**ناقص:**
- **بحث** + **فلترة بالتصنيف/التاريخ/المبلغ**.
- **أيقونة/شعار التاجر** (لو متاح) بدل أيقونة التصنيف فقط.
- **Swipe actions** (تغيير تصنيف / حذف بالسحب).
- **Sticky date headers** + skeleton أثناء التحميل.

### 3.3 Reports / Charts (أكبر فجوة)
**ناقص:**
- **Trend line/bar** للصرف عبر الأيام (عندنا `dailySpend` في الـ data جاهز بس مش مرسوم!).
- **Donut** لتوزيع التصنيفات.
- **مقارنة بصرية** بين الفترات (this vs prev) كـ bars متجاورة.
- **drill-down** لكل تصنيف (اتجاهه + أكثر متاجره).

### 3.4 Budgets
**ناقص:**
- **حلقة تقدّم (ring)** بدل/بجانب الـ bar (Apple Fitness style).
- **ألوان حالة متحركة** (انتقال أخضر→أصفر→أحمر).
- **توقّع**: «بالمعدل ده هتتجاوز يوم X».

### 3.5 Goals / Vault (رمز الهوية)
**ناقص:**
- **خزنة Rive** متحركة (تمتلئ بسلاسة + عملات تتساقط + لمعان عند 100%).
- **احتفال confetti/Rive** عند تحقيق milestone.
- **bar تقدّم زمني** (متبقّي X يوم، موصى Y/يوم).

### 3.6 Gamification
**ناقص:**
- **Celebration overlay غني** (confetti + Rive + haptic) بدل بانر بسيط.
- **شريط XP متحرك** + animation عند كسب XP.
- **streak flame** متحركة + «freeze» بصري.

### 3.7 Motion & Micro-interactions (عام)
**ناقص في كل التطبيق:**
- **Haptic feedback** عند التأكيد/الإنجاز/الأخطاء.
- **Page/hero transitions** (العملية → تفاصيلها بانتقال سلس).
- **Staggered entrance** للقوائم والبطاقات.
- **Pressable scale** على البطاقات (تصغير لمسي).

### 3.8 States (Empty/Loading/Error)
**ناقص:**
- **Skeleton loaders** (shimmer) لكل شاشة قائمة.
- **Empty states برسوم** (illustration + نبرة ودّية).
- **Error ودّي** برسم + زر إعادة.

### 3.9 Onboarding
**جيد بعد التحديث**، لكن:
- **حركة على الصفحات** (parallax/fade للأيقونات).
- **عدّاد/animation** على صفحة الخزنة.

### 3.10 Settings / Profile
**ناقص:**
- **header بروفايل** (اللوجو/avatar + الاسم + المستوى).
- **أقسام مجمّعة** بعناوين + أيقونات متّسقة (يحل تحذيرات ListTile كمان).

---

## 4. الحزم المقترحة (Dependencies)
```yaml
fl_chart: ^0.69.0          # رسوم بيانية (line/bar/donut)
flutter_animate: ^4.5.0    # حركة تصريحية بسيطة (fade/slide/scale/shimmer)
skeletonizer: ^1.4.0       # skeleton loaders تلقائية
confetti: ^0.8.0           # احتفالات
# rive موجودة (للخزنة)
# haptic: استخدم HapticFeedback من flutter/services (مدمج)
```

---

## 5. خارطة الأولويات
| الأولوية | الحزمة | الأثر |
|---|---|---|
| **P0** | Charts في Dashboard + Reports (`fl_chart`) | أكبر قفزة بصرية |
| **P0** | Skeleton loaders (`skeletonizer`) | إحساس premium فوري |
| **P0** | Motion أساسي (`flutter_animate`) + haptics + count-up | حياة وحيوية |
| **P1** | الخزنة Rive + Celebrations (`confetti`/Rive) | الهوية + المتعة |
| **P1** | بحث/فلترة + swipe في العمليات | وظيفة قوية |
| **P1** | drill-down تصنيف + budget rings | عمق |
| **P2** | Empty/Error illustrations + Settings/Profile redesign | صقل |

---

## 6. مهام جاهزة لـ Codex (Per-area Tasks)

> System prompt المعتاد (CODEX_HANDOFF §12) + التزام DESIGN_SYSTEM (Vibrant، Lucide، RTL، بدون إيموجي، AppLucideIcons). كل دفعة: `flutter analyze` + `flutter test` خضراء.

**Task UI-1 — Charts (P0):**
```
فعّل fl_chart. أضف:
1) في Dashboard: donut chart لتوزيع التصنيفات (من data.topCategories) + sparkline/bar صغير لاتجاه الصرف (استخدم بيانات يومية — أضف dailyExpenseTotals للشهر إن لزم).
2) في Reports (reports_screen): bar chart للصرف اليومي (ReportSection.dailySpend جاهز!) + donut للتصنيفات + bars متجاورة this vs prev.
أنشئ widgets قابلة لإعادة الاستخدام في features/common/charts/. ألوان من c (primary/accent/category colors). RTL-aware. اختبارات widget بسيطة (smoke).
```

**Task UI-2 — Skeleton & Motion (P0):**
```
1) استبدل CircularProgressIndicator في الشاشات الرئيسية (Dashboard/Transactions/Reports/Budgets/Goals) بـ skeleton loaders (skeletonizer) تحاكي شكل المحتوى.
2) أضف flutter_animate: staggered fade+slide للبطاقات/القوائم عند الظهور (مع احترام reduce-motion).
3) أضف count-up animation للأرقام البطلة (وفّرت/الصرف) — TweenAnimationBuilder.
4) أضف HapticFeedback (selectionClick عند الاختيار، mediumImpact عند تأكيد عملية/تحقيق هدف).
```

**Task UI-3 — Vault Rive + Celebrations (P1):**
```
1) استبدل VaultWidget الحالي بأصل Rive (خزنة تمتلئ بـ progress 0..1 + عملات تتساقط + لمعان عند 100%). أبقِ نسخة 2D احتياطية عند reduce-motion/فشل التحميل. ضع الأصل في assets/rive/vault.riv.
2) Celebration overlay غني: confetti + رسالة + haptic عند: تحقيق هدف، فتح شارة، streak milestone. يُغلق تلقائياً.
```

**Task UI-4 — Transactions قوية (P1):**
```
في transactions_screen: أضف شريط بحث + فلترة (تصنيف/نوع/مدى تاريخ) + Swipe actions (تغيير تصنيف/حذف) + sticky date headers + skeleton. حدّث transaction_repository بـ query بحث/فلترة.
```

**Task UI-5 — Category drill-down + Budget rings (P1):**
```
1) شاشة تفاصيل تصنيف: اتجاه صرفه (line)، أكثر متاجره، عملياته، مقارنة بالشهر السابق. تُفتح بالضغط على تصنيف في Dashboard/Reports.
2) Budgets: أضف ring progress (CustomPainter أو fl_chart) بجانب الـ bar + انتقال لوني متحرك + سطر توقّع التجاوز.
```

**Task UI-6 — States & Settings polish (P2):**
```
1) Empty/Error states: رسوم توضيحية (SVG بسيطة أو Rive) + نبرة ودّية + زر فعل.
2) Settings/Profile: header (لوجو/avatar + الاسم + المستوى + streak) + أقسام مجمّعة (Card sections) بعناوين، وحلّ تحذيرات ListTile (غلّفها بـ Material/Card).
```

---

## 7. توصية البدء
ابدأ بـ **Task UI-1 (Charts) + UI-2 (Skeleton/Motion/Haptics)** — دول بيدّوا **80% من إحساس الـ "wow"** بأقل مجهود، وبيحوّلوا الانطباع من «نظيف» لـ «قوي». بعدها UI-3 (الخزنة Rive + الاحتفالات) للهوية والمتعة.
