import '../entities/card_entity.dart';

/// مستودع البطاقات الحقيقية (جدول `cards`). كل الكتابات محلية أولاً
/// (offline-first)؛ القراءات دائمًا من Drift.
abstract class CardRepository {
  /// كل البطاقات غير المحذوفة.
  Future<List<CardEntity>> getAll();

  /// بطاقات حساب محدد.
  Future<List<CardEntity>> getByAccount(String accountId);

  Future<CardEntity?> getById(String id);

  /// إيجاد بطاقة بحسابها وآخر 4 أرقام مُطبَّعة — أساس مطابقة الرسائل ومنع
  /// التكرار داخل نفس الحساب.
  Future<CardEntity?> findByAccountAndLast4(String accountId, String last4);

  Future<CardEntity> create(CardEntity card);

  Future<CardEntity> update(CardEntity card);

  /// نقل البطاقة لحساب آخر. لا يُحرّك العمليات التاريخية (account_id مستقل).
  Future<CardEntity> moveToAccount({
    required String cardId,
    required String newAccountId,
  });

  /// حذف ناعم. لا يمسّ عمليات البطاقة (card_last4 يبقى على العمليات).
  Future<void> delete(String id);

  /// تعبئة أوّلية آمنة من العمليات الموجودة (بطاقات مُكتشفة تلقائيًا لكل
  /// حساب). idempotent — لا يكرّر ولا يمسّ البطاقات اليدوية. يعيد عدد المُنشأة.
  Future<int> backfillFromTransactions();

  /// MALI-017 — عدد البطاقات النشطة التي لا يمكن للسحابة استيعابها بعد
  /// (بطاقة بلا حساب أو تحمل حقول تصميم بينما `kUserCardsCloudV2=false`) ولم
  /// تُزامَن (server_id فارغ). هذه البيانات محلية فقط وستُفقد عند تسجيل الخروج/
  /// إعادة التثبيت ما لم يأخذ المستخدم نسخة احتياطية — تُستخدم لتحذيره قبل المسح
  /// المُدمّر بدلًا من فقدانها بصمت. تُعيد 0 عندما تدعم السحابة كل الحقول.
  Future<int> countCapabilityGatedUnsyncedCards();
}
