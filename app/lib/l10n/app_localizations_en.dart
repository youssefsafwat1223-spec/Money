// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppL10nEn extends AppL10n {
  AppL10nEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Mali';

  @override
  String get next => 'Next';

  @override
  String get skip => 'Skip';

  @override
  String get registerAndStart => 'Register and Start';

  @override
  String get welcomeTitle => 'Your Daily Financial Companion';

  @override
  String get welcomeSubtitle => 'Your buddy with your money';
}
