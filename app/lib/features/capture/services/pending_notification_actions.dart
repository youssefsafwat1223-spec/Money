import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// مخزن احتياطي لإجراءات الإشعارات (تأكيد/تجاهل) التي فشلت في الـ background —
/// مثلاً عند الضغط على "تأكيد ✓" والجهاز مقفول فلا يمكن قراءة مفتاح التشفير من
/// الـ Keychain. تُحفظ في ملف وتُطبَّق عند أول فتح للتطبيق.
class PendingNotificationActions {
  const PendingNotificationActions._();

  static const String _fileName = 'pending_notification_actions.json';

  static Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File(p.join(directory.path, _fileName));
  }

  static Future<void> record(String transactionId,
      {required bool confirm}) async {
    try {
      final file = await _file();
      final actions = await _read(file);
      actions.removeWhere((a) => a['transactionId'] == transactionId);
      actions.add({'transactionId': transactionId, 'confirm': confirm});
      await file.writeAsString(jsonEncode(actions), flush: true);
    } catch (_) {
      // الملف احتياطي أصلاً — لا شيء أكثر يمكن فعله هنا.
    }
  }

  /// يسحب الإجراءات المعلّقة ويمسح الملف. يعيد قائمة فارغة إن لم يوجد شيء.
  static Future<List<({String transactionId, bool confirm})>> drain() async {
    try {
      final file = await _file();
      final actions = await _read(file);
      if (actions.isEmpty) return const [];
      await file.delete();
      return [
        for (final a in actions)
          if (a['transactionId'] is String)
            (
              transactionId: a['transactionId'] as String,
              confirm: a['confirm'] == true,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Map<String, dynamic>>> _read(File file) async {
    if (!await file.exists()) return [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return [];
      return decoded.whereType<Map<String, dynamic>>().toList();
    } on FormatException {
      return [];
    }
  }
}
