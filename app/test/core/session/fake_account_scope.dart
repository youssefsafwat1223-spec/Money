import 'package:money_companion/core/session/account_scope.dart';

/// Records the calls AppSession makes on the account-scope layer.
class FakeAccountScope implements AccountScopeControl {
  FakeAccountScope([List<String>? sink]) : calls = sink ?? [];
  final List<String> calls;
  Object? lockError;
  Object? activateError;

  @override
  Future<void> activate(String uid) async {
    calls.add('activate:$uid');
    if (activateError != null) throw activateError!;
  }

  @override
  Future<void> lock() async {
    calls.add('lock');
    if (lockError != null) throw lockError!;
  }

  @override
  Future<void> detach() async => calls.add('detach');
}
