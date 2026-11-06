import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/session/app_session.dart';
import '../app/app_boot_loader.dart';
import '../../core/startup/automatic_session_recovery.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/theme/widgets/glass_dialog.dart';

/// First-use guidance with live, measured targets. Missing/offscreen targets
/// fall back to a readable card; no rectangle is guessed or cached across steps.
class CoachMark {
  const CoachMark({
    required this.icon,
    required this.title,
    required this.body,
    this.target,
  });

  final IconData icon;
  final String title;
  final String body;
  final GlobalKey? target;
}

/// Stable ids. Changing one re-shows that tour; the id is the identity, so it
/// must not be derived from copy that translators may edit.
abstract final class CoachMarkIds {
  static const String dashboard = 'dashboard.v1';
  static const String budgets = 'budgets.v1';
  static const String bills = 'bills.v1';
}

/// Shows [marks] once for [id], then records it as seen.
///
/// A no-op when already seen, when [marks] is empty, or when the context is
/// gone by the time it runs. Returns true when the tour was actually shown.
bool _tourOpen = false;

class _GuideAnchors extends InheritedWidget {
  const _GuideAnchors({required this.keys, required super.child});
  final Map<String, GlobalKey> keys;
  static _GuideAnchors? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_GuideAnchors>();

  @override
  bool updateShouldNotify(_GuideAnchors oldWidget) => keys != oldWidget.keys;
}

class CoachAnchor extends StatelessWidget {
  const CoachAnchor({super.key, required this.target, required this.child});
  final String target;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final key = _GuideAnchors.of(context)
        ?.keys
        .putIfAbsent(target, () => GlobalKey(debugLabel: 'guide-$target'));
    return KeyedSubtree(key: key, child: child);
  }
}

Future<bool> showCoachMarksOnce(
  BuildContext context, {
  required String id,
  required List<CoachMark> marks,
}) async {
  if (marks.isEmpty ||
      _tourOpen ||
      appDataRestoring.value ||
      AutomaticSessionRecovery.restoringSession.value) {
    return false;
  }
  if (AppSession.instance.hasSeenCoachMark(id)) return false;
  if (!context.mounted) return false;

  _tourOpen = true;
  try {
    await showDialog<void>(
      context: context,
      barrierColor:
          marks.any((m) => m.target != null) ? Colors.transparent : null,
      barrierDismissible: true,
      useSafeArea: false,
      builder: (_) => _CoachMarkTour(marks: marks),
    );
  } finally {
    _tourOpen = false;
  }
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
  Rect? _target;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  void _measure() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final anchor = widget.marks[_index].target?.currentContext;
      if (anchor != null) {
        await Scrollable.ensureVisible(anchor,
            alignment: .4,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 200));
      }
      if (!mounted) return;
      final box = anchor?.findRenderObject();
      final rect = box is RenderBox && box.attached && box.hasSize
          ? box.localToGlobal(Offset.zero) & box.size
          : null;
      setState(() => _target = rect);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final mark = widget.marks[_index];
    final isLast = _index == widget.marks.length - 1;

    final card = GlassAlertDialog(
      scrollableContent: true,
      // AlertDialog rather than a bare Dialog: Dialog passes an unbounded width
      // down to its own Material, so any content that cannot size itself
      // intrinsically — a Spacer, an Expanded, a long unconstrained Text —
      // throws "BoxConstraints forces an infinite width" during layout.
      // AlertDialog handles the intrinsic sizing, and its actions row is
      // exactly what this tour needs.
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
              setState(() {
                _index++;
                _target = null;
              });
              _measure();
            }
          },
          child: Text(isLast ? l10n.coachMarkDone : l10n.coachMarkNext),
        ),
      ],
    );
    final target = _target;
    if (target == null) return SafeArea(child: card);
    final size = MediaQuery.sizeOf(context);
    return Stack(children: [
      Positioned.fill(
          child: IgnorePointer(
              child:
                  CustomPaint(painter: _SpotlightPainter(target.inflate(8))))),
      Theme(
          data: Theme.of(context).copyWith(
              dialogTheme: DialogTheme.of(context).copyWith(
                  alignment: target.center.dy > size.height / 2
                      ? Alignment.topCenter
                      : Alignment.bottomCenter,
                  insetPadding: const EdgeInsets.all(16))),
          child: SafeArea(child: card)),
    ]);
  }
}

class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter(this.rect);
  final Rect rect;
  @override
  void paint(Canvas canvas, Size size) {
    final hole = RRect.fromRectAndRadius(rect, const Radius.circular(16));
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(hole);
    canvas.drawPath(
        shade, Paint()..color = Colors.black.withValues(alpha: .72));
    canvas.drawRRect(
        hole,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter old) => old.rect != rect;
}

/// Wait for real content, completed restore and the active route before opening
/// a tour. Async loading/errors never consume its once-only marker.
class FirstUseGuide extends StatefulWidget {
  const FirstUseGuide(
      {super.key, required this.id, required this.marks, required this.child});
  final String id;
  final List<CoachMark> Function(BuildContext) marks;
  final Widget child;
  @override
  State<FirstUseGuide> createState() => _FirstUseGuideState();
}

class _FirstUseGuideState extends State<FirstUseGuide> {
  final _keys = <String, GlobalKey>{};
  final _contentKey = GlobalKey();
  Timer? _timer;
  int _checks = 0;
  bool _offered = false;
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant FirstUseGuide old) {
    super.didUpdateWidget(old);
    if (!_offered) {
      _checks = 0;
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (AppSession.instance.status != SessionStatus.authenticated) return;
    _timer = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted || _offered) return;
      if (AppSession.instance.hasSeenCoachMark(widget.id)) {
        _offered = true;
        return;
      }
      final content = _contentKey.currentContext;
      if (content == null) return;
      final marks = widget.marks(content);
      final ready = !appDataRestoring.value &&
          !AutomaticSessionRecovery.restoringSession.value &&
          ModalRoute.of(context)?.isCurrent == true &&
          !_tourOpen &&
          marks.isNotEmpty &&
          marks.every((m) => m.target?.currentContext != null);
      if (!ready) {
        if (++_checks < 80) _schedule();
        return;
      }
      _offered = true;
      final shown =
          await showCoachMarksOnce(context, id: widget.id, marks: marks);
      if (!shown && mounted) {
        _offered = false;
        _schedule();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _GuideAnchors(
        keys: _keys,
        child: KeyedSubtree(key: _contentKey, child: widget.child),
      );
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
  final l = context.l10n;
  final keys = _GuideAnchors.of(context)?.keys ?? const <String, GlobalKey>{};
  return [
    CoachMark(
        icon: AppLucideIcons.plus,
        title: l.coachDashboardAddTitle,
        body: l.coachDashboardAddBody,
        target: keys['add']),
    CoachMark(
        icon: AppLucideIcons.clipboardPaste,
        title: l.coachPasteTitle,
        body: l.coachPasteBody,
        target: keys['paste']?.currentContext == null
            ? keys['add']
            : keys['paste']),
    if (keys['account']?.currentContext != null)
      CoachMark(
          icon: AppLucideIcons.wallet,
          title: l.coachAccountTitle,
          body: l.coachAccountBody,
          target: keys['account']),
    if (keys['period']?.currentContext != null)
      CoachMark(
          icon: AppLucideIcons.calendarCheck,
          title: l.coachDashboardPeriodTitle,
          body: l.coachDashboardPeriodBody,
          target: keys['period']),
  ];
}

List<CoachMark> budgetCoachMarks(BuildContext context) => [
      CoachMark(
          icon: AppLucideIcons.pieChart,
          title: context.l10n.coachBudgetTitle,
          body: context.l10n.coachBudgetBody,
          target: _GuideAnchors.of(context)?.keys['budgetAdd']),
    ];
List<CoachMark> billCoachMarks(BuildContext context) => [
      CoachMark(
          icon: AppLucideIcons.calendarCheck,
          title: context.l10n.coachBillsTitle,
          body: context.l10n.coachBillsBody,
          target: _GuideAnchors.of(context)?.keys['billAdd']),
    ];
