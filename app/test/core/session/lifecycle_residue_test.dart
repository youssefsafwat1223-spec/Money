import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';

/// MALI-054n / MALI-011 / MALI-017: destructive-lifecycle residue purge +
/// fail-closed cross-user admission. Exercises AppSession through its injected
/// wipe/purge hooks (the production wiring), asserting that one identity's
/// native/file capture residue can never carry into another.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var wipeCalls = 0;
  var purgeCalls = 0;
  var purgeResult = true;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    wipeCalls = 0;
    purgeCalls = 0;
    purgeResult = true;
    AppSession.instance.configureCaptureDeviceUnlink(null);
    AppSession.instance.configureLocalDataWipe(() async => wipeCalls++);
    AppSession.instance.configureLocalResiduePurge(() async {
      purgeCalls++;
      return purgeResult;
    });
    await AppSession.instance.wipeAndReset();
    wipeCalls = 0;
    purgeCalls = 0;
  });

  tearDown(() async {
    AppSession.instance.configureLocalDataWipe(null);
    AppSession.instance.configureLocalResiduePurge(null);
    await AppSession.instance.wipeAndReset();
  });

  Future<String?> owner() => AppSession.instance.readLocalDataOwnerUid();

  test('sign-out runs the residue purge and, on success, clears the owner marker',
      () async {
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
    expect(await owner(), 'uid-a');

    await AppSession.instance.signOut();

    expect(purgeCalls, greaterThanOrEqualTo(1), reason: 'residue purged');
    expect(await owner(), isNull, reason: 'ownership released after clean purge');
  });

  test(
      'sign-out that CANNOT confirm the purge keeps the owner marker so the next '
      'different user is forced through the fail-closed conflict path', () async {
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
    purgeResult = false; // native/file purge cannot be confirmed

    await AppSession.instance.signOut();

    expect(purgeCalls, greaterThanOrEqualTo(1));
    expect(await owner(), 'uid-a',
        reason: 'owner marker retained until residue is confirmed purged');
  });

  test(
      'cross-user admission is FAIL-CLOSED: if the previous owner\'s residue '
      'purge fails, the new identity is refused and the DB stays owned by A',
      () async {
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
    expect(await owner(), 'uid-a');

    purgeResult = false; // B's admission must fail closed
    await expectLater(
      AppSession.instance.setIdentity(method: 'google', userId: 'uid-b'),
      throwsA(isA<LocalDataOwnershipException>()),
    );

    // CONTRACT CHANGE (2026-09-27): A's data is NOT wiped here any more.
    //
    // This used to assert `wipeCalls >= 1` — the transition wiped first and
    // purged second. That ordering destroyed every TestFlight user's data on
    // every launch: the purge calls a method channel that is not registered
    // during `didFinishLaunchingWithOptions` under the UIScene lifecycle, so it
    // failed, the bail-out below left the owner marker stranded, and the next
    // launch repeated the wipe. See ownership_transition_order_test.dart.
    //
    // The security property this test is actually about is untouched and still
    // asserted: B is REFUSED and the DB stays owned by A. Not destroying A's
    // rows on the way to refusing B is strictly safer — B is never admitted, so
    // there is nothing for the wipe to protect against here.
    expect(wipeCalls, 0,
        reason: 'a purge that cannot be confirmed must not cost A their data');
    expect(await owner(), 'uid-a',
        reason: 'ownership NOT transferred to B while residue may remain');
    expect(AppSession.instance.status, isNot(SessionStatus.authenticated));
  });

  test(
      'cross-user admission SUCCEEDS once residue purge is confirmed: A wiped, '
      'residue purged, ownership transferred to B', () async {
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
    wipeCalls = 0;
    purgeCalls = 0;

    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-b');

    expect(wipeCalls, greaterThanOrEqualTo(1));
    expect(purgeCalls, greaterThanOrEqualTo(1));
    expect(await owner(), 'uid-b');
  });

  test('the full reset (wipeAndReset) also purges native/file residue', () async {
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
    purgeCalls = 0;

    await AppSession.instance.wipeAndReset();

    expect(purgeCalls, greaterThanOrEqualTo(1));
    expect(await owner(), isNull);
  });
}
