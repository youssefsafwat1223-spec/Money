import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// هيكل شاشة قياسي — خلفية، SafeArea، header اختياري، padding آمن.
///
/// [bottomNavPadding]: علامة أن الشاشة تعمل تحت شريط تنقل عائم.
/// لا نضغط الـ body نفسه بهذه المسافة حتى لا يظهر كسر بصري في منتصف الشاشة؛
/// الشاشات القابلة للتمرير تضيف مسافة النهاية داخل الـ ListView/Sliver نفسها.
///
/// لا تُطبَّق على كل الشاشات بعد — مكوّن جاهز للمراحل 4-9.
class AppScreenScaffold extends StatelessWidget {
  const AppScreenScaffold({
    super.key,
    required this.body,
    this.header,
    this.padding,
    this.bottomNavPadding,
    this.resizeToAvoidBottomInset = true,
    this.extendBodyBehindHeader = false,
  });

  final Widget body;

  /// Widget فوق المحتوى (مثل SectionHeroHeader). يُعرَض قبل [body].
  final Widget? header;

  /// padding للمحتوى داخل body. إذا null، لا padding.
  final EdgeInsetsGeometry? padding;

  /// مسافة إضافية في الأسفل لتجنب تغطية شريط التنقل العائم.
  /// القيمة المعتادة: ~80px لشريط التنقل العائم في Mali.
  final double? bottomNavPadding;

  final bool resizeToAvoidBottomInset;
  final bool extendBodyBehindHeader;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget content = body;

    if (padding != null) {
      content = Padding(padding: padding!, child: content);
    }

    final bodyColumn = Column(
      children: [
        if (header != null) header!,
        Expanded(child: content),
      ],
    );

    return Scaffold(
      backgroundColor: c.bg,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      extendBodyBehindAppBar: extendBodyBehindHeader,
      body: SafeArea(
        bottom: bottomNavPadding == null,
        child: bodyColumn,
      ),
    );
  }
}
