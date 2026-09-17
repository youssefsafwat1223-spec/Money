import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/main.dart';

class _ImmediateFailureRunner extends BootstrapRunner {
  var calls = 0;

  @override
  Future<AppDatabase> run() async {
    calls += 1;
    throw StateError('test bootstrap failure');
  }
}

void main() {
  testWidgets('paints the startup spinner before bootstrap can replace it',
      (tester) async {
    final runner = _ImmediateFailureRunner();

    await tester.pumpWidget(StartupApp(runner: runner));

    // `StartupApp` builds its own MaterialApp and now carries the localization
    // delegates, so it resolves against the DEVICE locale — the saved language
    // lives in the database, which is exactly what has not opened yet. The
    // test binding's locale is en-US, so this is the English copy. The strings
    // came from hardcoded Arabic literals before, which is why this test could
    // not tell the two builds apart.
    expect(find.text('Getting Qirsh ready…'), findsOneWidget);
    expect(find.text('Qirsh could not start'), findsNothing);
    expect(runner.calls, 1);

    await tester.pump();

    expect(find.text('Getting Qirsh ready…'), findsNothing);
    expect(find.text('Qirsh could not start'), findsOneWidget);
  });
}
