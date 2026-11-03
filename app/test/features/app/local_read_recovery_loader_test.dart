import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/local_read_providers.dart';
import 'package:money_companion/core/startup/automatic_session_recovery.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/app/app_boot_loader.dart';
import 'package:money_companion/features/app/local_read_shell.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _HeldRecovery extends Fake implements AutomaticSessionRecovery {
  final done = Completer<void>();

  @override
  Future<void> quiesced() => done.future;
}

void main() {
  const reconnect = Key('local_read_reconnect');

  for (final finishesEarly in [true, false]) {
    testWidgets('recovery loader reveals fallback, early=$finishesEarly',
        (tester) async {
      final previous = AutomaticSessionRecovery.active;
      final recovery = _HeldRecovery();
      AutomaticSessionRecovery.active = recovery;
      addTearDown(() => AutomaticSessionRecovery.active = previous);
      var reconnects = 0;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          localReadSnapshotProvider.overrideWith(
            (_) async => const LocalReadSnapshot([], []),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: LocalReadShell(onReconnect: () => reconnects++),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(AppBootLoader), findsOneWidget);
      expect(find.byKey(reconnect), findsNothing);

      if (finishesEarly) {
        recovery.done.complete();
        await tester.pump();
      } else {
        await tester.pump(const Duration(milliseconds: 1399));
        expect(find.byType(AppBootLoader), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(find.byType(AppBootLoader), findsNothing);
      expect(find.byKey(reconnect), findsOneWidget);
      await tester.tap(find.byKey(reconnect));
      expect(reconnects, 1);

      if (!finishesEarly) recovery.done.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AppBootLoader), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
