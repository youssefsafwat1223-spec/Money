import '../../data/catalog/feature_flag_service.dart';
import '../../data/db/app_database.dart';
import '../../data/db/financial_cache_health.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/repositories/bill_repository.dart';

class RoutedBillRepository implements BillRepository {
  const RoutedBillRepository({
    required BillRepository drift,
    required BillRepository supabase,
    required FeatureFlagService Function() flags,
    required AppDatabase db,
  })  : _drift = drift,
        _supabase = supabase,
        _flags = flags,
        _db = db;

  final BillRepository _drift;
  final BillRepository _supabase;
  final FeatureFlagService Function() _flags;
  final AppDatabase _db;
  bool get _useSupabase => _flags().getBool('subscriptions_supabase_primary');
  Future<T> _route<T>(
    Future<T> Function() supabase,
    Future<T> Function() drift,
  ) =>
      routeFinancialOperation(
        db: _db,
        entityType: subscriptionsCacheEntityType,
        useSupabase: _useSupabase,
        supabase: supabase,
        drift: drift,
      );

  @override
  Future<void> delete(String id) =>
      _route(() => _supabase.delete(id), () => _drift.delete(id));
  @override
  Future<void> deletePayment(String paymentId) => _route(
        () => _supabase.deletePayment(paymentId),
        () => _drift.deletePayment(paymentId),
      );
  @override
  Future<List<String>> deletePaymentForTransaction(String transactionId) =>
      _route(
        () => _supabase.deletePaymentForTransaction(transactionId),
        () => _drift.deletePaymentForTransaction(transactionId),
      );
  @override
  Future<List<BillEntity>> getAll() => _route(_supabase.getAll, _drift.getAll);
  @override
  Future<BillEntity?> getById(String id) =>
      _route(() => _supabase.getById(id), () => _drift.getById(id));
  @override
  Future<List<BillEntity>> getDueBetween(
          {required DateTime from, required DateTime to}) =>
      _route(
        () => _supabase.getDueBetween(from: from, to: to),
        () => _drift.getDueBetween(from: from, to: to),
      );
  @override
  Future<List<BillPaymentEntity>> getPayments(String billId) => _route(
        () => _supabase.getPayments(billId),
        () => _drift.getPayments(billId),
      );
  @override
  Future<BillPaymentEntity> recordPayment(BillPaymentEntity payment) => _route(
        () => _supabase.recordPayment(payment),
        () => _drift.recordPayment(payment),
      );
  @override
  Future<BillEntity> save(BillEntity bill) =>
      _route(() => _supabase.save(bill), () => _drift.save(bill));
}
