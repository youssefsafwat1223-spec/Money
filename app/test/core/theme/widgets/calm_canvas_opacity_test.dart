import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/mali_tokens.dart';
import 'package:money_companion/core/theme/widgets/calm_canvas.dart';

Future<List<int>> _sample(WidgetTester tester, {required bool dark,
    required bool ambient, required bool includeUnderlay}) async {
  final boundary = GlobalKey();
  final canvas = CalmCanvas(ambient: ambient, child: const SizedBox.expand());
  await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr,
    child: Theme(data: dark ? AppTheme.dark : AppTheme.light,
      child: Center(child: SizedBox(width: 400, height: 800,
        child: includeUnderlay
            ? RepaintBoundary(key: boundary, child: ColoredBox(
                color: const Color(0xFFFF00FF), child: canvas))
            : ColoredBox(color: const Color(0xFFFF00FF),
                child: RepaintBoundary(key: boundary, child: canvas)),
      )),
    ),
  ));
  await tester.runAsync(() => precacheImage(
      const AssetImage('assets/textures/grain.png'), boundary.currentContext!));
  await tester.pumpAndSettle();
  final pixel = await tester.runAsync(() async {
    final image = await (boundary.currentContext!.findRenderObject()
        as RenderRepaintBoundary).toImage(pixelRatio: 1);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      // Outside the top/bottom aurora blobs and past the top radial glow.
      final offset = (400 * image.width + 200) * 4;
      return [for (var channel = 0; channel < 4; channel++)
        bytes.getUint8(offset + channel)];
    } finally {
      image.dispose();
    }
  });
  return pixel!;
}

void main() {
  for (final dark in [false, true]) {
    for (final ambient in [false, true]) {
      testWidgets('canvas stays opaque over a contrasting host: dark=$dark ambient=$ambient', (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final canvas = await _sample(tester, dark: dark, ambient: ambient,
            includeUnderlay: false);
        final composite = await _sample(tester, dark: dark, ambient: ambient,
            includeUnderlay: true);
        expect(canvas[3], 255,
            reason: 'the canvas itself must be opaque, including where its glow is transparent');
        expect(composite, canvas,
            reason: 'the magenta host must not show through the canvas');
        final base = dark ? MaliTokens.dark.canvas : MaliTokens.light.canvas;
        final channels = [(base.r * 255).round(), (base.g * 255).round(),
          (base.b * 255).round()];
        for (var channel = 0; channel < 3; channel++) {
          expect(canvas[channel], closeTo(channels[channel], 15),
              reason: 'the base palette stays visible beneath the faint grain');
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
