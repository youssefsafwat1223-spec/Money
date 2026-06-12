// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppL10nAr extends AppL10n {
  AppL10nAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'مالي';

  @override
  String get next => 'التالي';

  @override
  String get skip => 'تخطي';

  @override
  String get registerAndStart => 'التسجيل والبدء';

  @override
  String get welcomeTitle => 'مساعدك المالي اليومي';

  @override
  String get welcomeSubtitle => 'صاحبك في فلوسك';

  @override
  String get today => 'اليوم';

  @override
  String get yesterday => 'أمس';
}
