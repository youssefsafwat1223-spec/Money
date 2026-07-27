import 'package:flutter/widgets.dart';

import 'category_emoji.dart';

/// يرسم أيقونة تصنيف كإيموجي Unicode أصلي عبر [Text]، متوسّطًا داخل صندوق
/// مقاسه [size] — فيظهر في منتصف التايل بغضّ النظر عن محاذاة الأب.
///
/// [name] مفتاح الأيقونة النصّي كما يُخزَّن في الـ DB (نفس مفاتيح Lucide) —
/// يُحوَّل داخليًا إلى الإيموجي المقابل بواسطة [categoryEmoji].
///
/// لا نفرض عائلة خطّ، فيستخدم كل جهاز خط الإيموجي الملوّن الأصلي تلقائيًا
/// (Apple Color Emoji / Noto Color Emoji). [color] تُقبل للتوافق مع مواقع
/// الاستدعاء لكنها تُتجاهَل — الإيموجي ملوّن بذاته.
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
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          categoryEmoji(name),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: size * 0.92, height: 1),
        ),
      ),
    );
  }
}
