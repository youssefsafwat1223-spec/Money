import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';

/// هيكل شاشة قياسي — خلفية مع أوربت مضيئة خافتة للوضع الداكن، SafeArea، وهيدر اختياري.
class AppScreenScaffold extends StatelessWidget {
  const AppScreenScaffold({
    super.key,
    required this.body,
    this.header,
    this.padding,
    this.bottomNavPadding,
    this.bottomArea,
    this.resizeToAvoidBottomInset = true,
    this.extendBodyBehindHeader = false,
    this.safeArea = true,
    this.ambient = true,
  });

  final Widget body;

  /// Widget فوق المحتوى. يُعرَض قبل [body].
  final Widget? header;

  /// padding للمحتوى داخل body.
  final EdgeInsetsGeometry? padding;

  /// مسافة إضافية في الأسفل لتجنب تغطية شريط التنقل العائم.
  final double? bottomNavPadding;

  /// مساحة ثابتة اختيارية أسفل المحتوى، مثل أزرار إجراءات الشاشة.
  final Widget? bottomArea;

  final bool resizeToAvoidBottomInset;
  final bool extendBodyBehindHeader;
  final bool safeArea;
  final bool ambient;

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
        if (bottomArea != null)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              AppSpacing.gutter,
              AppSpacing.s3,
              AppSpacing.gutter,
              AppSpacing.s3,
            ),
            child: bottomArea!,
          ),
      ],
    );

    // شبكة الإضاءة المحيطية - تدعم الهوية البصرية الفاخرة للوضع الداكن
    Widget baseBackground = Container(
      color: c.bg,
    );

    if (isDark && ambient) {
      baseBackground = Stack(
        children: [
          Positioned.fill(child: Container(color: c.bg)),
          // هالة بنفسجية خفيفة في الأعلى، ثابتة ورخيصة بصريًا.
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
          // هالة وردية خافتة في الأسفل، بلا blur أو shader.
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
                    c.accent.withValues(alpha: 0.035),
                    c.accent.withValues(alpha: 0.0),
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
          _MaybeSafeArea(
            enabled: safeArea,
            bottom: bottomNavPadding == null,
            child: Padding(
              padding: EdgeInsetsDirectional.only(
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

class _MaybeSafeArea extends StatelessWidget {
  const _MaybeSafeArea({
    required this.enabled,
    required this.bottom,
    required this.child,
  });

  final bool enabled;
  final bool bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return SafeArea(bottom: bottom, child: child);
  }
}
