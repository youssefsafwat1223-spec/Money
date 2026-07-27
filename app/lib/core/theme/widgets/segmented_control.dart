import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';

/// One option in a [SegmentedControl].
class SegmentOption<T> {
  const SegmentOption({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// SegmentedControl — a calm pill selector (add-sheet type, report tabs). The
/// selected segment lifts on [MaliTokens.surfaceFloating] (or the accent
/// gradient when [accent] is set). Pure presentation + a callback.
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.accent = false,
  });

  final List<SegmentOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.surfaceRaised,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        children: [
          for (final o in options)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(o.value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    color: value == o.value && !accent
                        ? t.surfaceFloating
                        : Colors.transparent,
                    gradient: value == o.value && accent
                        ? MaliTokens.accentGradient
                        : null,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (o.icon != null) ...[
                        Icon(
                          o.icon,
                          size: 16,
                          color: _fg(t, o.value),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          o.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.subhead(_fg(t, o.value)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Color _fg(MaliTokens t, T v) {
    if (value == v) {
      return accent ? Colors.white : t.textOnCanvasPrimary;
    }
    return t.textOnCanvasSecondary;
  }
}
