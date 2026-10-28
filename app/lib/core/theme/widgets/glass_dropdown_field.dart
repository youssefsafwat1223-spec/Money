import 'package:flutter/material.dart';

import '../../utils/app_lucide_icons.dart';
import '../app_colors.dart';
import '../app_spacing.dart';
import 'glass_sheet.dart';

/// A form field that picks one of [items] from a Liquid Glass sheet — the
/// iOS 26 replacement for [DropdownButtonFormField], whose Material popup is
/// an opaque menu that no theme can turn into glass.
///
/// Same inputs as the dropdown it replaces ([value] or [initialValue],
/// [items], [onChanged], [decoration], [validator]); a null [onChanged]
/// disables it. It joins the enclosing [Form] so `validate()` still works.
class GlassDropdownField<T> extends StatefulWidget {
  const GlassDropdownField({
    super.key,
    required this.items,
    required this.onChanged,
    this.value,
    this.initialValue,
    this.decoration,
    this.style,
    this.validator,
    this.isDense = false,
    this.isExpanded = true,
  });

  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final T? value;
  final T? initialValue;
  final InputDecoration? decoration;
  final TextStyle? style;
  final FormFieldValidator<T>? validator;
  final bool isDense;

  /// Kept for call-site parity with [DropdownButtonFormField]; the field
  /// always fills its width.
  final bool isExpanded;

  @override
  State<GlassDropdownField<T>> createState() => _GlassDropdownFieldState<T>();
}

/// Wraps the picked value so a legitimately null item stays distinguishable
/// from a dismissed sheet.
class _Picked<T> {
  const _Picked(this.value);
  final T? value;
}

class _GlassDropdownFieldState<T> extends State<GlassDropdownField<T>> {
  late T? _value = widget.value ?? widget.initialValue;

  @override
  void didUpdateWidget(GlassDropdownField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) _value = widget.value;
  }

  DropdownMenuItem<T>? get _selectedItem {
    for (final item in widget.items) {
      if (item.value == _value) return item;
    }
    return null;
  }

  /// The app palette, or the stock one when this field sits under a theme
  /// without it (bare `ThemeData` in tests and some dialogs).
  AppColors get _colors =>
      Theme.of(context).extension<AppColors>() ??
      (Theme.of(context).brightness == Brightness.dark
          ? AppColors.dark
          : AppColors.light);

  Future<void> _open() async {
    final c = _colors;
    final picked = await showGlassSheet<_Picked<T>>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: AppSpacing.s3),
            children: [
              for (final item in widget.items)
                ListTile(
                  enabled: item.enabled,
                  title: DefaultTextStyle.merge(
                    style: TextStyle(color: c.textPrimary),
                    child: item.child,
                  ),
                  trailing: item.value == _value
                      ? Icon(AppLucideIcons.check, color: c.cta, size: 20)
                      : null,
                  onTap: () {
                    item.onTap?.call();
                    Navigator.of(sheetContext).pop(_Picked<T>(item.value));
                  },
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _value = picked.value);
    widget.onChanged?.call(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.onChanged != null;
    final selected = _selectedItem;
    final base = widget.decoration ?? const InputDecoration();
    return FormField<T>(
      initialValue: _value,
      // Validates the field's CURRENT value, which this state owns.
      validator:
          widget.validator == null ? null : (_) => widget.validator!(_value),
      builder: (field) => Semantics(
        button: true,
        enabled: enabled,
        child: InkWell(
          onTap: enabled
              ? () async {
                  await _open();
                  field.didChange(_value);
                }
              : null,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: InputDecorator(
            isEmpty: selected == null,
            decoration: base.copyWith(
              enabled: enabled,
              isDense: widget.isDense ? true : base.isDense,
              errorText: field.errorText,
              suffixIcon: base.suffixIcon ??
                  Icon(AppLucideIcons.chevronDown,
                      size: 18, color: _colors.textSecondary),
            ),
            child: DefaultTextStyle(
              style: widget.style ?? theme.textTheme.titleMedium!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: selected?.child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}
