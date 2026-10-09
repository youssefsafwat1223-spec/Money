import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'f2_fixture.dart';
import 'recording_secure_storage.dart';

// F2 — the remount boundary. The observed race ran through the generation-keyed
// ProviderScope: Remove data's `detach` publishes the signed-out scope, the root
// remounts the tree under a new generation, the shell's first frame revalidates
// the (still live) Supabase session.
//
// This harness reproduces main.dart's `ProviderScope(key: ValueKey(generation))`
// over the REAL AccountScopeHost and the REAL AppSession, with a go_router that
// mirrors app_router.dart's status redirect, and a shell probe that makes the
// same call AppShell makes (`AppSession.revalidateForShell`) at its first frame.
//
// GAP (stated plainly): the real `AppShell`/`MoneyApp`/`appRouter` are not
// mounted — they need the full provider graph, notifications and native
// channels. The one decision AppShell makes about this race is a single call
// into AppSession, which is what the probe exercises; AppShell's own
// `mounted` checks are not covered here.

class _Harness extends StatefulWidget {
  const _Harness({
    required this.host,
    required this.client,
    required this.honorStatusInRouter,
    required this.onShellMounted,
  });

  final AccountScopeHost host;
  final SupabaseClient client;
  final bool honorStatusInRouter;
  final void Function(_ShellProbeState shell) onShellMounted;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final GoRouter _router = GoRouter(
    refreshListenable: AppSession.instance,
    redirect: (context, state) {
      // Mirrors app_router.dart: needsOnboarding/sessionExpired go to sign-in.
      // `honorStatusInRouter: false` models a router that still permits the
      // shell (stale router state): router state must not be the fence.
      if (!widget.honorStatusInRouter) return null;
      final status = AppSession.instance.status;
      if (status == SessionStatus.authenticated) {
        return state.matchedLocation == '/' ? null : '/';
      }
      return state.matchedLocation == '/auth' ? null : '/auth';
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => _ShellProbe(
            client: widget.client, onMounted: widget.onShellMounted),
      ),
      GoRoute(path: '/auth', builder: (_, __) => const Text('signed-out')),
    ],
  );

  @override
  void initState() {
    super.initState();
    widget.host.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.host.removeListener(_rebuild);
    _router.dispose(); // it listens to the AppSession singleton
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = widget.host.current;
    if (scope == null) return const SizedBox.shrink();
    return ProviderScope(
      key: ValueKey(scope.generation), // main.dart:125
      overrides: [appDatabaseProvider.overrideWithValue(scope.database)],
      child: MaterialApp.router(routerConfig: _router),
    );
  }
}

class _ShellProbe extends ConsumerStatefulWidget {
  const _ShellProbe({required this.client, required this.onMounted});
  final SupabaseClient client;
  final void Function(_ShellProbeState) onMounted;

  @override
  ConsumerState<_ShellProbe> createState() => _ShellProbeState();
}

class _ShellProbeState extends ConsumerState<_ShellProbe> {
  /// What AppShell does at its first frame: revalidate, and only when that says
  /// the session is authenticated run the Supabase-primary startup work.
  Future<bool> revalidate() =>
      AppSession.instance.revalidateForShell(widget.client);

  var startupWorkRuns = 0;

  @override
  void initState() {
    super.initState();
    widget.onMounted(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!await revalidate()) return;
      startupWorkRuns++;
    });
  }

  @override
  Widget build(BuildContext context) => const Text('shell');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  late SupabaseClient client;
  final session = AppSession.instance;
  final shells = <_ShellProbeState>[];

  setUp(() => shells.clear());

  /// Frames and real time alternate: the probes' futures live in the fake-async
  /// zone while the fixture's file/database I/O needs real time.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
    }
  }

  Future<void> bootSignedInX(WidgetTester tester,
      {required bool honorStatusInRouter}) async {
    await tester.runAsync(() async {
      // Production waits for a frame after withdrawing a scope (main.dart's
      // host is built with `afterWithdraw: WidgetsBinding.instance.endOfFrame`),
      // so the old tree is gone before the new generation mounts.
      f = await F2Fixture.create(
          afterWithdraw: () => WidgetsBinding.instance.endOfFrame);
      await f.signIn('uid-x');
      client = await f.clientFor('uid-x');
    });
    await tester.pumpWidget(_Harness(
      host: f.host,
      client: client,
      honorStatusInRouter: honorStatusInRouter,
      onShellMounted: shells.add,
    ));
    await settle(tester);
    expect(find.text('shell'), findsOneWidget);
    expect(shells, hasLength(1));
    expect(shells.single.startupWorkRuns, 1, reason: 'the signed-in shell works');
  }

  /// Zones: continuations registered inside the fake-async zone (the shell's own
  /// futures, the host's serialization tail) only run on a pump, so waiting for
  /// the removal inside `runAsync` alone would deadlock. Alternate pumps with
  /// real time until the condition holds.
  Future<void> pumpUntil(WidgetTester tester, bool Function() cond) async {
    for (var i = 0; i < 400 && !cond(); i++) {
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(cond(), isTrue, reason: 'condition not reached');
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    var disposed = false;
    await tester.runAsync(() async {
      unawaited(f.dispose().then((_) => disposed = true));
    });
    await pumpUntil(tester, () => disposed);
  }

  testWidgets('router honors status: the remounted tree shows signed-out, no '
      'shell mounts, nothing for X is activated, keyed or written',
      (tester) async {
    await bootSignedInX(tester, honorStatusInRouter: true);
    final retained = shells.single.revalidate; // a callback from the OLD shell
    final hashX = await tester.runAsync(() => f.hash('uid-x'));
    final from = f.storage.attempts.length;

    var done = false;
    f.scope.holdAfterDetach = Hold();
    await tester.runAsync(() async {
      unawaited(session.removeDataFromDevice().then((_) => done = true));
    });
    await pumpUntil(tester, () => f.scope.holdAfterDetach!.reached.isCompleted);
    // detach published the signed-out scope: new generation, remounted tree.
    await tester.pump();
    await tester.pump();
    expect(f.host.current!.uid, isNull);
    expect(find.text('signed-out'), findsOneWidget);
    expect(find.text('shell'), findsNothing);
    expect(shells, hasLength(1), reason: 'no shell mounted for the new generation');

    final retainedResult = retained();
    f.scope.holdAfterDetach!.release.complete();
    await pumpUntil(tester, () => done);
    expect(await retainedResult, isFalse, reason: 'a retained old-shell callback');

    final writes = f.storage.attempts.skip(from).where((a) =>
        a.startsWith('write:$kMarkerKey=') ||
        a.startsWith('write:$kGenerationKey=') ||
        a.startsWith('write:qirsh.db_key.'));
    expect(writes, isEmpty);
    expect(f.replicaDir(hashX!).existsSync(), isFalse);
    expect(await tester.runAsync(() => f.artifactsOf('uid-x')), isEmpty);
    expect(f.host.current!.uid, isNull);
    await finish(tester);
  });

  testWidgets('a router that STILL permits the shell (stale router state): the '
      'shell remounts, its first-frame revalidation is refused, no startup '
      'work, no X activation/key/seed', (tester) async {
    await bootSignedInX(tester, honorStatusInRouter: false);
    final retained = shells.single.revalidate;
    final from = f.storage.attempts.length;

    var done = false;
    f.scope.holdAfterDetach = Hold();
    await tester.runAsync(() async {
      unawaited(session.removeDataFromDevice().then((_) => done = true));
    });
    await pumpUntil(tester, () => f.scope.holdAfterDetach!.reached.isCompleted);
    await settle(tester);

    expect(shells.length, 2, reason: 'the shell DID remount (router not the fence)');
    expect(shells.last.startupWorkRuns, 0,
        reason: 'revalidateForShell refuses: status is not authenticated');

    final retainedResult = retained();
    final freshResult = shells.last.revalidate();
    f.scope.holdAfterDetach!.release.complete();
    await pumpUntil(tester, () => done);
    expect(await retainedResult, isFalse);
    expect(await freshResult, isFalse);

    final writes = f.storage.attempts.skip(from).where((a) =>
        a.startsWith('write:$kMarkerKey=') ||
        a.startsWith('write:$kGenerationKey=') ||
        a.startsWith('write:qirsh.db_key.'));
    expect(writes, isEmpty);
    expect(await tester.runAsync(() => f.artifactsOf('uid-x')), isEmpty);
    expect(shells.last.startupWorkRuns, 0);
    await finish(tester);
  });
}
