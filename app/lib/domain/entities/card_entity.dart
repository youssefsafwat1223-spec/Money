import '../../engine/parser/card_network.dart';

/// مصدر اكتشاف البطاقة: يدوي (أضافها المستخدم) أو تلقائي (من رسالة بنكية).
enum CardSource { manual, auto }

CardSource cardSourceFromKey(String key) =>
    key == 'auto' ? CardSource.auto : CardSource.manual;

/// بطاقة حقيقية مملوكة لحساب واحد — مصدر الحقيقة لهوية البطاقة وبياناتها.
/// مختلفة عن `CardSummary` (نموذج قراءة مُشتَقّ من العمليات).
class CardEntity {
  const CardEntity({
    required this.id,
    required this.accountId,
    required this.last4,
    required this.network,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.nickname,
    this.colorTheme,
    this.accentHex,
  });

  final String id;

  /// الحساب المرتبط — قد يكون null (بطاقة غير مخصّصة لأي حساب).
  final String? accountId;

  /// آخر 4 أرقام مُطبَّعة (أرقام فقط). مفتاح الربط داخل الحساب.
  final String last4;
  final CardNetwork network;
  final CardSource source;
  final String? nickname;

  /// مفتاح ثيم التصميم (من kCardThemes) — null = الثيم الافتراضي.
  final String? colorTheme;

  /// لون مميّز اختياري (#RRGGBB) يطغى على نهاية التدرّج.
  final String? accentHex;

  final DateTime createdAt;
  final DateTime updatedAt;

  CardEntity copyWith({
    String? id,
    String? accountId,
    String? last4,
    CardNetwork? network,
    CardSource? source,
    String? nickname,
    String? colorTheme,
    String? accentHex,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CardEntity(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      last4: last4 ?? this.last4,
      network: network ?? this.network,
      source: source ?? this.source,
      nickname: nickname ?? this.nickname,
      colorTheme: colorTheme ?? this.colorTheme,
      accentHex: accentHex ?? this.accentHex,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// يُطبّع آخر 4 أرقام: يُبقي الأرقام فقط ويأخذ آخر 4. يعيد null لو أقل من 4.
String? normalizeLast4(String? raw) {
  if (raw == null) return null;
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < 4) return null;
  return digits.substring(digits.length - 4);
}
