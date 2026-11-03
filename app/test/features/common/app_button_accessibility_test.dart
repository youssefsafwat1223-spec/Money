import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_spacing.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/common/app_button.dart';

Widget _button(String variant, String label, VoidCallback onTap,
    {bool disabled = false, bool loading = false, double height = 52}) {
  const key = ValueKey('tested-button');
  return switch (variant) {
    'secondary' => AppSecondaryButton(key: key, label: label, onTap: onTap,
      disabled: disabled, loading: loading, height: height, icon: Icons.check,
      semanticsLabel: 'Verified action'),
    'ghost' => AppGhostButton(key: key, label: label, onTap: onTap,
      disabled: disabled, loading: loading, height: height, icon: Icons.check,
      semanticsLabel: 'Verified action'),
    'danger' => AppDangerButton(key: key, label: label, onTap: onTap,
      disabled: disabled, loading: loading, height: height, icon: Icons.check,
      semanticsLabel: 'Verified action'),
    _ => AppPrimaryButton(key: key, label: label, onTap: onTap,
      disabled: disabled, loading: loading, height: height, icon: Icons.check,
      semanticsLabel: 'Verified action'),
  };
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final variant in ['primary', 'secondary', 'ghost', 'danger']) {
      testWidgets('$variant long label wraps fully and preserves interaction at375 2x $language',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        try {
        await tester.runAsync(() async {
          final fonts = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await fonts.load();
        });
        final label = language == 'ar'
            ? 'احفظ جميع التغييرات وتابع إلى الخطوة التالية'
            : 'Save all changes and continue to the next step';
        var calls = 0;
        Future<void> pump({bool disabled = false, bool loading = false}) async {
          await tester.pumpWidget(MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
            home: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Directionality(textDirection: language == 'ar' ? TextDirection.rtl : TextDirection.ltr,
                child: Scaffold(body: Padding(padding: const EdgeInsets.all(16),
                  child: Center(child: SizedBox(width: double.infinity,
                    child: _button(variant, label, () => calls++, disabled: disabled, loading: loading)))))))));
          await tester.pump(const Duration(milliseconds: 400));
        }
        await pump();
        expect(tester.takeException(), isNull);
        final button = find.byKey(const ValueKey('tested-button'));
        final text = find.text(label);
        final bounds = tester.getRect(button);
        final textBounds = tester.getRect(text);
        expect(bounds.height, greaterThan(52));
        expect(textBounds.left, greaterThanOrEqualTo(bounds.left));
        expect(textBounds.right, lessThanOrEqualTo(bounds.right));
        expect(textBounds.top, greaterThanOrEqualTo(bounds.top));
        expect(textBounds.bottom, lessThanOrEqualTo(bounds.bottom));
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(tester.widget<Text>(text).maxLines, isNull);
        final node = tester.getSemantics(button);
        expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
        expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
        expect(node.label, contains('Verified action'));
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(calls, 1);

        await pump(disabled: true);
        expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed, isNull);
        expect(tester.getSemantics(button).hasFlag(SemanticsFlag.isEnabled), isFalse);
        await tester.tap(button);
        await tester.pump();
        expect(calls, 1);
        expect(tester.takeException(), isNull);

        await pump(loading: true);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text(label), findsNothing);
        expect(tester.getRect(button).height, 52);
        expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed, isNull);
        expect(tester.getSemantics(button).hasFlag(SemanticsFlag.isEnabled), isFalse);
        await tester.tap(button);
        expect(calls, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('one-line default button retains its configured minimum height', (tester) async {
    for (final variant in ['primary', 'secondary', 'ghost', 'danger']) {
      final button = _button(variant, 'Save', () {}, height: AppSpacing.buttonHeight);
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light,
        home: Scaffold(body: Center(child: button))));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const ValueKey('tested-button'))).height,
          AppSpacing.buttonHeight);
      expect(tester.takeException(), isNull);
    }
  });
}
