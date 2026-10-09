import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/admission_authority.dart';

/// Records the calls AppSession makes on the account-scope layer.
class FakeAccountScope implements AccountScopeControl {
  FakeAccountScope([List<String>? sink]) : calls = sink ?? [];
  final List<String> calls;

  /// The uid whose scope is "published" (null = signed-out).
  @override
  String? activeUid;
  Object? lockError;
  Object? activateError;

  /// The authority each activation carried (F2), in order.
  final List<AdmissionAuthority?> authorities = [];

  @override
  Future<void> activate(String uid, {AdmissionAuthority? authority}) async {
    authority?.requireCurrent();
    authorities.add(authority);
    calls.add('activate:$uid');
    activeUid = uid;
    if (activateError != null) throw activateError!;
  }

  @override
  Future<void> lock() async {
    calls.add('lock');
    if (lockError != null) throw lockError!;
  }

  @override
  Future<void> detach() async => calls.add('detach');

  @override
  Future<void> suspendForSwap() async => calls.add('suspendForSwap');
}
