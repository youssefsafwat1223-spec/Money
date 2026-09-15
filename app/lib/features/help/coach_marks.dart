import 'package:flutter/material.dart';

import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';

/// V1 guidance, Layer A (charter: REQUIRED_PRODUCT_CHANGE_5).
///
/// Contextual first-use guidance. Shown once per mark, then out of the way —
/// the persistent half lives on the Help screen, which can replay these.
///
/// Deliberately NOT a spotlight cut-out over a captured widget rectangle. That
/// approach has to resolve a `GlobalKey`'s render box at the exact moment the
/// route settles, and gets it wrong on any screen whose content arrives
/// asynchronously — which is most of this app's screens. A sequence of centred
/// cards carries the same information and cannot point at the wrong place.
class CoachMark {
  const CoachMark({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;
}

/// Stable ids. Changing one re-shows that tour; the id is the identity, so it
/// must not be derived from copy that translators may edit.
abstract final class CoachMarkIds {
  static const String dashboard = 'dashboard.v1';
}

/// Shows [marks] once for [id], then records it as seen.
///
/// A no-op when already seen, when [marks] is empty, or when the context is
/// gone by the time it runs. Returns true when the tour was actually shown.
Future<bool> showCoachMarksOnce(
  BuildContext context, {
  required String id,
  required List<CoachMark> marks,
}) async {
  if (marks.isEmpty) return false;
  if (AppSession.instance.hasSeenCoachMark(id)) return false;
  if (!context.mounted) return false;

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _CoachMarkTour(marks: marks),
  );
  // Recorded AFTER the tour closes, and regardless of how it closed: someone
  // who dismisses guidance has still been offered it, and re-showing it on
  // every launch would be the more annoying failure.
  await AppSession.instance.markCoachMarkSeen(id);
  return true;
}

class _CoachMarkTour extends StatefulWidget {
  const _CoachMarkTour({required this.marks});

  final List<CoachMark> marks;

  @override
  State<_CoachMarkTour> createState() => _CoachMarkTourState();
}

class _CoachMarkTourState extends State<_CoachMarkTour> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final mark = widget.marks[_index];
    final isLast = _index == widget.marks.length - 1;

    return AlertDialog(
      // AlertDialog rather than a bare Dialog: Dialog passes an unbounded width
      // down to its own Material, so any content that cannot size itself
      // intrinsically — a Spacer, an Expanded, a long unconstrained Text —
      // throws "BoxConstraints forces an infinite width" during layout.
      // AlertDialog handles the intrinsic sizing, and its actions row is
      // exactly what this tour needs.
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Icon(mark.icon, color: c.primary, size: 22),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              mark.title,
              style: AppTypography.bodyStrong(c.textMain),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(mark.body, style: AppTypography.caption(c.textLight)),
          const SizedBox(height: AppSpacing.s4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Progress, so the tour never feels open-ended.
              for (var i = 0; i < widget.marks.length; i++)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: Container(
                    width: i == _index ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _index ? c.primary : c.border,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.coachMarkSkip),
        ),
        FilledButton(
          onPressed: () {
            if (isLast) {
              Navigator.of(context).pop();
            } else {
              setState(() => _index++);
            }
          },
          child: Text(isLast ? l10n.coachMarkDone : l10n.coachMarkNext),
        ),
      ],
    );
  }
}

/// The tour widget, exposed for widget tests. Production code goes through
/// [showCoachMarksOnce], which adds the once-only persistence around it.
@visibleForTesting
class CoachMarkTourForTest extends StatelessWidget {
  const CoachMarkTourForTest({super.key, required this.marks});

  final List<CoachMark> marks;

  @override
  Widget build(BuildContext context) => _CoachMarkTour(marks: marks);
}

/// The dashboard tour — the first surface anyone lands on after onboarding.
List<CoachMark> dashboardCoachMarks(BuildContext context) {
  final l10n = context.l10n;
  return [
    CoachMark(
      icon: AppLucideIcons.plus,
      title: l10n.coachDashboardAddTitle,
      body: l10n.coachDashboardAddBody,
    ),
    CoachMark(
      icon: AppLucideIcons.calendarCheck,
      title: l10n.coachDashboardPeriodTitle,
      body: l10n.coachDashboardPeriodBody,
    ),
    CoachMark(
      icon: AppLucideIcons.inbox,
      title: l10n.coachDashboardInboxTitle,
      body: l10n.coachDashboardInboxBody,
    ),
    CoachMark(
      icon: AppLucideIcons.helpCircle,
      title: l10n.coachDashboardHelpTitle,
      body: l10n.coachDashboardHelpBody,
    ),
  ];
}
