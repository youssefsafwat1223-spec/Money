import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/mali_tokens.dart';
import 'package:money_companion/core/theme/widgets/mali_screen.dart';

void main() {
  testWidgets('renders child mode on the black canvas', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MaliScreen(child: Text('hello')),
      ),
    );
    expect(find.text('hello'), findsOneWidget);
    final decoratedBox = tester.widget<DecoratedBox>(
      find.byType(DecoratedBox).first,
    );
    final decoration = decoratedBox.decoration as BoxDecoration;
    expect(decoration.color, MaliTokens.light.canvas);
  });

  testWidgets('renders slivers mode in a CustomScrollView', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MaliScreen(
          slivers: [
            SliverToBoxAdapter(child: Text('sliver content')),
          ],
        ),
      ),
    );
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.text('sliver content'), findsOneWidget);
  });

  test('asserts exactly one of child/slivers is provided', () {
    expect(
      () => MaliScreen(slivers: const [], child: const Text('a')),
      throwsAssertionError,
    );
    expect(() => MaliScreen(), throwsAssertionError);
  });

  testWidgets(
      'provides a DefaultTextStyle so descendant text has no fallback '
      'yellow-underline decoration', (tester) async {
    late TextStyle inherited;
    await tester.pumpWidget(
      MaterialApp(
        home: MaliScreen(
          child: Builder(
            builder: (context) {
              inherited = DefaultTextStyle.of(context).style;
              return const Text('x');
            },
          ),
        ),
      ),
    );
    // The debug fallback style is red text + a double yellow underline; our
    // canvas style is white text with no decoration.
    expect(inherited.decoration ?? TextDecoration.none, TextDecoration.none);
    expect(inherited.color, MaliTokens.light.textOnCanvasPrimary);
  });

  testWidgets('provides a Material ancestor for descendants', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: MaliScreen(child: Text('x'))),
    );
    expect(find.byType(Material), findsWidgets);
  });
}
