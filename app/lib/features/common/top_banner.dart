import 'package:flutter/material.dart';

import '../../core/theme/widgets/app_toast.dart';

void showTopError(BuildContext context, String message) {
  AppToast.showError(context, message);
}

void showTopInfo(BuildContext context, String message) {
  AppToast.show(context, message);
}
