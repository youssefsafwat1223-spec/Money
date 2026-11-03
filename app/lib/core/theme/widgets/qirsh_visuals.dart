import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app_colors.dart';

/// The original photographs approved in the HTML reference. Every image is
/// bundled locally; showing one never depends on Cloud consent or a network.
enum QirshPhoto {
  growth('qirsh-financial-growth', 'insight', Alignment(-0.32, 0.10)),
  jar('qirsh-savings-jar-v2', 'savings', Alignment(-0.34, 0.08)),
  goals('qirsh-savings-goals', 'savings', Alignment(-0.32, 0.08)),
  wallet('qirsh-budget-wallet-v4', 'budget', Alignment(-0.32, 0.04)),
  analytics('qirsh-financial-analytics', 'reports', Alignment(-0.32, 0.08)),
  milestone('qirsh-goal-milestone-v2', 'achievements', Alignment(-0.38, -0.16)),
  cards('qirsh-accounts-cards-v4', 'accounts', Alignment(-0.32, 0.04)),
  brand('qirsh-brand-hero-v3', 'welcome', Alignment(-0.32, -0.08)),
  travel('goal-travel-north-coast-v2', 'goalTravel', Alignment(-0.32, 0.12)),
  emergency('goal-emergency-fund', 'goalEmergency', Alignment(-0.34, 0.04)),
  laptop('goal-new-laptop', 'savings', Alignment(-0.32, 0.06)),
  car('goal-new-car', 'savings', Alignment(-0.26, 0.02)),
  home('goal-new-home', 'savings', Alignment(-0.32, 0.10)),
  education('goal-education', 'savings', Alignment(-0.32, 0.20));

  const QirshPhoto(this.fileName, this.illustrationName, this.focalOffset);

  final String fileName;
  final String illustrationName;

  /// Focal points from the approved photo manifest, mapped from percentages to
  /// Flutter's -1..1 alignment. Subjects stay on the physical left in RTL/LTR.
  final Alignment focalOffset;

  String get assetPath => 'assets/photos/$fileName.webp';
}

/// Artwork follows existing goal skins only; unknown skins keep the neutral
/// savings composition. No goal name, balance or account data is reinterpreted.
QirshPhoto qirshGoalPhoto(String vaultSkin) => switch (vaultSkin) {
      'summer_trip' => QirshPhoto.travel,
      'emergency_fund' => QirshPhoto.emergency,
      'photo:travel' => QirshPhoto.travel,
      'photo:car' => QirshPhoto.car,
      'photo:home' => QirshPhoto.home,
      'photo:education' => QirshPhoto.education,
      'photo:laptop' => QirshPhoto.laptop,
      'photo:emergency' => QirshPhoto.emergency,
      _ => QirshPhoto.goals,
    };

/// An exact light/dark export of the prototype's flat illustration system.
/// Art is not directionally mirrored: its original composition is preserved.
class QirshIllustration extends StatelessWidget {
  const QirshIllustration({
    super.key,
    required this.name,
    this.width = 160,
    this.height = 120,
    this.fit = BoxFit.contain,
    this.semanticsLabel,
  });

  static const names = <String>[
    'accounts',
    'achievements',
    'bills',
    'budget',
    'capture',
    'dataTransfer',
    'emptyTx',
    'goalEmergency',
    'goalTravel',
    'help',
    'insight',
    'notifications',
    'offers',
    'plans',
    'privacy',
    'referral',
    'reports',
    'reviewDone',
    'savings',
    'transactions',
    'welcome',
  ];

  final String name;
  final double? width;
  final double? height;
  final BoxFit fit;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    assert(names.contains(name), 'Unknown Qirsh illustration: $name');
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SvgPicture.asset(
      'assets/illustrations/${dark ? 'dark/' : ''}$name.svg',
      width: width,
      height: height,
      fit: fit,
      semanticsLabel: semanticsLabel,
      excludeFromSemantics: semanticsLabel == null,
    );
  }
}

/// A local photo with its original focal crop. The illustration is used only
/// after an actual asset-loading/decoding error, never instead of a valid photo.
class QirshPhotoFrame extends StatelessWidget {
  const QirshPhotoFrame({
    super.key,
    required this.photo,
    required this.height,
    this.width,
    this.fit = BoxFit.cover,
    this.focalOffset,
    this.semanticsLabel,
  });

  final QirshPhoto photo;
  final double height;
  final double? width;
  final BoxFit fit;
  final Alignment? focalOffset;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      photo.assetPath,
      width: width,
      height: height,
      fit: fit,
      alignment: focalOffset ?? photo.focalOffset,
      excludeFromSemantics: semanticsLabel == null,
      semanticLabel: semanticsLabel,
      errorBuilder: (context, error, stackTrace) => SizedBox(
        width: width,
        height: height,
        child: ColoredBox(
          color: context.colors.surfaceMuted,
          child: Center(
            child: QirshIllustration(
              name: photo.illustrationName,
              semanticsLabel: semanticsLabel,
            ),
          ),
        ),
      ),
    );
  }
}

/// The HTML `.photo-card`: 26pt corners, an original photograph and a navy
/// scrim. Text stays on the physical right, preserving the clear space in the
/// approved compositions in both languages. The minimum height can grow with
/// localized copy or accessibility text scaling rather than clipping content.
class QirshPhotoCard extends StatelessWidget {
  const QirshPhotoCard({
    super.key,
    required this.photo,
    required this.child,
    this.height = 196,
    this.minHeight,
    this.margin = const EdgeInsets.symmetric(horizontal: 16),
    this.padding,
    this.borderRadius = 26,
    this.copyWidthFactor = 0.60,
    this.focalOffset,
    this.semanticsLabel,
  }) : assert(copyWidthFactor > 0 && copyWidthFactor <= 1);

  final QirshPhoto photo;
  final Widget child;
  final double height;
  final double? minHeight;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry? padding;
  final double borderRadius;
  final double copyWidthFactor;
  final Alignment? focalOffset;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final effectiveHeight = minHeight ?? height;
    final copyPadding = padding ??
        EdgeInsets.fromLTRB(
            Directionality.of(context) == TextDirection.rtl ? 4 : 8, 16, 16, 16);
    return Container(
      margin: margin,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF0A2540),
        borderRadius: BorderRadius.circular(borderRadius),
        border: dark ? Border.all(color: context.colors.border) : null,
        boxShadow: dark
            ? null
            : const [
                BoxShadow(
                    color: Color(0x0D0C1330),
                    offset: Offset(0, 2),
                    blurRadius: 6),
                BoxShadow(
                    color: Color(0x140C1330),
                    offset: Offset(0, 12),
                    blurRadius: 32),
              ],
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        return Stack(
          children: [
            Positioned.fill(
              child: QirshPhotoFrame(
                photo: photo,
                height: effectiveHeight,
                focalOffset: focalOffset,
                semanticsLabel: semanticsLabel,
              ),
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    colors: [
                      Color(0xEB06122E),
                      Color(0xBD06122E),
                      Color(0x1A06122E),
                      Color(0x0006122E),
                    ],
                    stops: [0, 0.40, 0.72, 1],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              heightFactor: 1,
              child: SizedBox(
                width: constraints.maxWidth * copyWidthFactor,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: effectiveHeight),
                  child: Padding(
                    padding: copyPadding,
                    child: DefaultTextStyle.merge(
                      style: const TextStyle(color: Colors.white),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [child],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

/// A rounded photographic banner for pushed screens and existing sheets.
class QirshPhotoBanner extends StatelessWidget {
  const QirshPhotoBanner({
    super.key,
    required this.photo,
    this.height = 188,
    this.margin = const EdgeInsets.fromLTRB(16, 4, 16, 14),
    this.borderRadius = 20,
    this.focalOffset,
    this.semanticsLabel,
  });

  final QirshPhoto photo;
  final double height;
  final EdgeInsetsGeometry margin;
  final double borderRadius;
  final Alignment? focalOffset;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => Padding(
        padding: margin,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: QirshPhotoFrame(
            photo: photo,
            height: height,
            width: double.infinity,
            focalOffset: focalOffset,
            semanticsLabel: semanticsLabel,
          ),
        ),
      );
}
