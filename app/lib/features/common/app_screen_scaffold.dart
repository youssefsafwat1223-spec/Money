import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// هيكل شاشة قياسي — خلفية مع أوربت مضيئة خافتة للوضع الداكن، SafeArea، وهيدر اختياري.
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

  /// Widget فوق المحتوى. يُعرَض قبل [body].
  final Widget? header;

  /// padding للمحتوى داخل body.
  final EdgeInsetsGeometry? padding;

  /// مسافة إضافية في الأسفل لتجنب تغطية شريط التنقل العائم.
  final double? bottomNavPadding;

  final bool resizeToAvoidBottomInset;
  final bool extendBodyBehindHeader;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
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

    // شبكة الإضاءة المحيطية - تدعم الهوية البصرية الفاخرة للوضع الداكن
    Widget baseBackground = Container(
      color: c.bg,
    );

    if (isDark) {
      baseBackground = Stack(
        children: [
          Positioned.fill(child: Container(color: c.bg)),
          // هالة زرقاء خفيفة في الأعلى
          Positioned(
            right: -100,
            top: -100,
            width: 320,
            height: 320,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    c.cta.withValues(alpha: 0.05),
                    c.cta.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          // هالة خضراء خفيفة في الأسفل
          Positioned(
            left: -120,
            bottom: -120,
            width: 360,
            height: 360,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    c.success.withValues(alpha: 0.04),
                    c.success.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      extendBodyBehindAppBar: extendBodyBehindHeader,
      body: Stack(
        children: [
          Positioned.fill(child: baseBackground),
          SafeArea(
            bottom: bottomNavPadding == null,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: bottomNavPadding ?? 0.0,
              ),
              child: bodyColumn,
            ),
          ),
        ],
      ),
    );
  }
}
