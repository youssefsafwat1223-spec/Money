import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture guard: `package:liquid_glass_renderer` is an internal
/// implementation detail of the MaliGlass advanced tier. Production code
/// must depend on MaliGlass only.
void main() {
  test('liquid_glass_renderer is imported only inside the glass boundary', () {
    const allowed = {
      'lib/core/theme/widgets/mali_glass_advanced.dart',
      'lib/features/design_gallery/design_gallery_screen.dart',
    };
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll('\\', '/');
      if (allowed.contains(path)) continue;
      if (entity
          .readAsStringSync()
          .contains('package:liquid_glass_renderer/')) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'Direct liquid_glass_renderer imports outside the MaliGlass '
            'adapter boundary. Route through MaliGlass instead.');
  });
}
