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
}
