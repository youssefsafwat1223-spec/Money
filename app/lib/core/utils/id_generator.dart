import 'dart:convert';
import 'dart:math';

/// يولّد معرّفات محلية مستقرة بدون الاعتماد على حزمة خارجية.
class IdGenerator {
  IdGenerator._();

  static final Random _random = Random.secure();

  static String next() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  /// معرّف UUID v4 قياسي — لازم لأعمدة `uuid` على Supabase (مثل
  /// notification_logs.id)، بخلاف [next] غير القياسي.
  static String uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}
