import 'package:flutter/widgets.dart';

import 'category_icon.dart';

/// يرسم أيقونة تصنيف كأيقونة خطّية (stroke) بلون التصنيف، متوسّطة داخل صندوق
/// مقاسه [size].
///
/// [name] مفتاح الأيقونة النصّي كما يُخزَّن في الـ DB (نفس مفاتيح Lucide).
///
/// ## Why this is no longer an emoji
///
/// This used to render a native colour emoji and DELIBERATELY ignored [color],
/// because an emoji carries its own. The design prototype draws a category as a
/// tinted box wrapping a 22px stroke glyph that takes the category's ink
/// colour, and the owner has made the prototype the authority: an emoji cannot
/// take a tint, cannot sit in the design's `.icobox`, and reads as a different
/// visual language from every other icon in the product.
///
/// [color] is now honoured. Callers pass the category's own colour, which is
/// what `--c-*-ink` is in the prototype.
class CategoryGlyph extends StatelessWidget {
  const CategoryGlyph({
    super.key,
    required this.name,
    required this.size,
    this.color,
  });

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final icon = categoryIconOrNull(name) ?? fallbackCategoryIcon;
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Icon(
          icon,
          size: size,
          color: color,
          // Only the transfer arrow mirrors — it means "from here to there".
          // A cup or a plane is an object, and objects do not flip.
          textDirection: categoryIconMirrors(name)
              ? Directionality.of(context)
              : TextDirection.ltr,
        ),
      ),
    );
  }
}
