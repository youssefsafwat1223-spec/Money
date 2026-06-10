# money_companion — Flutter App

تطبيق عربي لتتبع المصاريف تلقائياً من رسائل البنك (Arabic-first, on-device).
المواصفات الكاملة في مجلد الجذر: `../PRODUCT_SPEC.md` وأخواته. خطة التنفيذ: `../BUILD_PLAN.md`.

## الحالة الحالية (Sprint 0 + 1 — منجز)
- ✅ Foundation: Flutter + Riverpod + go_router + RTL (Arabic) + الثيمين.
- ✅ Theme tokens من `../DESIGN_SYSTEM.md` (Vibrant Fintech) — `lib/core/theme/`.
- ✅ IBM Plex Sans Arabic (google_fonts) + Lucide icons.
- ✅ Parser Engine (Dart نقي) — `lib/engine/parser/`.
- ✅ Categorization Engine (Dart نقي) — `lib/engine/categorization/`.
- ✅ Unit/golden tests للمحرك — `test/engine/`.
- 🟡 شاشة `FoundationHomeScreen` مؤقتة (smoke test) — تُستبدل لاحقاً.

## التشغيل
```bash
cd app
flutter create .            # يولّد android/ios/... دون المساس بـ lib/ و test/
flutter pub get
flutter test                # يجب أن تنجح اختبارات المحرك
flutter run                 # يفتح شاشة التأسيس (جرّب المحرك + بدّل الثيم)
```

## قواعد معمارية (للالتزام)
- `lib/engine/**` = Dart نقي، **ممنوع** استيراد `package:flutter`.
- `features/**` و`data/**` لا يستوردان `engine/parser` مباشرة — عبر usecases/repositories.
- التزام حرفي بـ `../DESIGN_SYSTEM.md` وقواعد العمل `../PRODUCT_SPEC.md` §24/§25.

## التالي (Sprint 2): قاعدة البيانات
انظر `../BUILD_PLAN.md` §4 + المهمة الجاهزة في نهاية رسالة التسليم.
