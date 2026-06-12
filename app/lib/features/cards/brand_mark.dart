import 'package:flutter/material.dart';

/// علامة العلامة التجارية (Brand mark) — لون + حرف مميّز للعلامات المعروفة،
/// وبديل افتراضي لأي متجر. مرسومة في Flutter (بلا أصول خارجية).
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.name, this.size = 44});

  final String name;
  final double size;

  static const Map<String, (Color, String)> _brands = {
    'NETFLIX': (Color(0xFFE50914), 'N'),
    'SPOTIFY': (Color(0xFF1DB954), 'S'),
    'SHAHID': (Color(0xFF00A19A), 'ش'),
    'شاهد': (Color(0xFF00A19A), 'ش'),
    'OSN': (Color(0xFF1A1A1A), 'O'),
    'ICLOUD': (Color(0xFF3B82F6), 'i'),
    'APPLE': (Color(0xFF1A1A1A), ''),
    'STC': (Color(0xFF4F008C), 'STC'),
    'MOBILY': (Color(0xFF00A551), 'M'),
    'ZAIN': (Color(0xFF6F2C91), 'Z'),
    'YOUTUBE': (Color(0xFFFF0000), 'Y'),
    'AMAZON': (Color(0xFFFF9900), 'a'),
  };

  @override
  Widget build(BuildContext context) {
    final upper = name.toUpperCase();
    Color color = const Color(0xFF0A2540);
    String label = name.isNotEmpty ? name.characters.first : '?';
    for (final entry in _brands.entries) {
      if (upper.contains(entry.key.toUpperCase())) {
        color = entry.value.$1;
        label = entry.value.$2.isEmpty
            ? (name.isNotEmpty ? name.characters.first : '?')
            : entry.value.$2;
        break;
      }
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * (label.length > 2 ? 0.32 : 0.46),
        ),
      ),
    );
  }
}
