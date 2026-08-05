// MALI-071n — merchant-logo consent boundary.
//
// Behavioral: pump BrandMark with cloud-processing consent overridden on/off
// and assert whether an outbound `Image` (network) widget is created at all —
// consent OFF must produce ZERO network image widgets, only bundled/placeholder.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/cards/brand_mark.dart';

Future<void> pumpMark(
  WidgetTester tester, {
  required bool allowRemote,
  required String name,
  String? logoUrl,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        remoteMerchantLogosAllowedProvider.overrideWithValue(allowRemote),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: BrandMark(name: name, logoUrl: logoUrl)),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('consent OFF makes ZERO network requests, even with a logoUrl',
      (tester) async {
    // TALABAT has a logo.dev domain AND we pass a catalog logoUrl — both remote.
    await pumpMark(
      tester,
      allowRemote: false,
      name: 'TALABAT',
      logoUrl: 'https://cdn.example.test/talabat.png',
    );
    expect(find.byType(Image), findsNothing); // no Image.network anywhere
    expect(find.byType(Text), findsWidgets); // letter-mark placeholder
  });

  testWidgets('consent ON fetches the catalog logoUrl over the network',
      (tester) async {
    await pumpMark(
      tester,
      allowRemote: true,
      name: 'TALABAT',
      logoUrl: 'https://cdn.example.test/talabat.png',
    );
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('consent ON falls back to logo.dev by public domain',
      (tester) async {
    // No catalog logoUrl → logo.dev path (sends the verified domain, not name).
    await pumpMark(tester, allowRemote: true, name: 'TALABAT');
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('bundled SVG shows offline with consent OFF and makes no request',
      (tester) async {
    await pumpMark(tester, allowRemote: false, name: 'NETFLIX');
    expect(find.byType(SvgPicture), findsOneWidget); // bundled, local
    expect(find.byType(Image), findsNothing); // never a network request
  });
}
