import 'package:flutter/widgets.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

extension L10nX on BuildContext {
  AppL10n get l10n => AppL10n.of(this);
}
