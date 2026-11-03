import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_typography.dart';

/// New section-only photography. Existing QirshPhoto assets stay in place.
enum QirshSectionPhoto {
  transactions,
  bills,
  budgets,
  goals,
  plans,
  accounts,
  cards,
  reports;

  String get asset => 'assets/photos/qirsh-section-$name-v1.webp';
}

const _sectionStatusColor = Color(0xFF0C1525);

/// Full-width photographic title with the next surface overlapping its foot.
///
/// Owns decoration only. Callers keep their routes, controls and money data.
class QirshSectionHero extends StatelessWidget {
  const QirshSectionHero({
    super.key,
    required this.photo,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.bottom,
    this.child,
    this.height = 220,
    this.useSafeAreaTop = true,
    this.expandForText = true,
  });

  final QirshSectionPhoto photo;
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? bottom;
  final Widget? child;
  final double height;
  final bool useSafeAreaTop;
  final bool expandForText;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final safeTop = useSafeAreaTop ? MediaQuery.paddingOf(context).top : 0.0;
    final textScaler = MediaQuery.textScalerOf(context);
    // Leave room for wrapping titles and large accessibility text above Search.
    final titleSpace =
        expandForText ? (textScaler.scale(24) - 24).clamp(0.0, 90.0) : 0.0;
    final photoHeight = height + safeTop + titleSpace;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Stack(
        children: [
          SizedBox(
            height: photoHeight,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ExcludeSemantics(
                  child: Image.asset(
                    photo.asset,
                    fit: BoxFit.cover,
                    alignment: const Alignment(0, .15),
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        _sectionStatusColor,
                        Color(0x8A040D20),
                        Color(0x22040D20)
                      ],
                      stops: [0, .6, 1],
                    ),
                  ),
                ),
                PositionedDirectional(
                  top: safeTop + AppSpacing.s3,
                  start: AppSpacing.gutter,
                  end: AppSpacing.gutter,
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      iconTheme: const IconThemeData(color: Colors.white),
                      textButtonTheme: TextButtonThemeData(
                        style:
                            TextButton.styleFrom(foregroundColor: Colors.white),
                      ),
                    ),
                    child: IconTheme(
                      data: const IconThemeData(color: Colors.white),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (leading != null) ...[
                            leading!,
                            const SizedBox(width: AppSpacing.s2),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(title,
                                    style: AppTypography.custom(
                                        size: 25,
                                        weight: FontWeight.w700,
                                        height: 1.25,
                                        letterSpacing: -.45,
                                        color: Colors.white)),
                                if (subtitle?.isNotEmpty == true) ...[
                                  const SizedBox(height: 5),
                                  Text(subtitle!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTypography.custom(
                                          size: 12.5,
                                          weight: FontWeight.w400,
                                          height: 1.4,
                                          color: const Color(0xFFE2E9F4))),
                                ],
                              ],
                            ),
                          ),
                          if (trailing != null) ...[
                            const SizedBox(width: AppSpacing.s2),
                            trailing!,
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (bottom != null)
                  PositionedDirectional(
                    start: AppSpacing.gutter,
                    end: AppSpacing.gutter,
                    bottom: 44,
                    child: bottom!,
                  ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: photoHeight - 28),
              Container(
                decoration: BoxDecoration(
                  color: c.bg,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(30)),
                ),
                padding: const EdgeInsets.only(top: AppSpacing.s3),
                child: child ?? const SizedBox(height: 16),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Extends the section's navy backdrop through the status-bar inset while the
/// SafeArea continues to keep pinned tabs clear of the clock after scrolling.
class QirshSectionBackdrop extends StatelessWidget {
  const QirshSectionBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    if (top <= 0) return child;
    return Stack(children: [
      child,
      Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: top,
          child: const AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: IgnorePointer(child: ColoredBox(color: _sectionStatusColor)),
          )),
    ]);
  }
}
