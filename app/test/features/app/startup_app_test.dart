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

    expect(find.text('جاري تجهيز التطبيق...'), findsOneWidget);
    expect(find.text('تعذّر تجهيز التطبيق'), findsNothing);
    expect(runner.calls, 1);

    await tester.pump();

    expect(find.text('جاري تجهيز التطبيق...'), findsNothing);
    expect(find.text('تعذّر تجهيز التطبيق'), findsOneWidget);
  });
}
