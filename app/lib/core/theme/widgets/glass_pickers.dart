import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_spacing.dart';
import 'glass_sheet.dart';

/// [showDatePicker] on the Liquid Glass sheet: the same calendar, presented
/// as a glass bottom sheet (the iOS 26 presentation) instead of an opaque
/// Material dialog. Same contract: the picked day, or null when dismissed.
Future<DateTime?> showGlassDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  return showGlassSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _GlassDateBody(
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    ),
  );
}

/// [showTimePicker] on the Liquid Glass sheet with the iOS time wheels,
/// always 12-hour (AM/PM) like the rest of the app.
Future<TimeOfDay?> showGlassTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
}) {
  return showGlassSheet<TimeOfDay>(
    context: context,
    builder: (sheetContext) => _GlassTimeBody(initialTime: initialTime),
  );
}

class _GlassDateBody extends StatefulWidget {
  const _GlassDateBody({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_GlassDateBody> createState() => _GlassDateBodyState();
}

class _GlassDateBodyState extends State<_GlassDateBody> {
  late DateTime _selected = DateUtils.dateOnly(widget.initialDate);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CalendarDatePicker(
            initialDate: _selected,
            firstDate: widget.firstDate,
            lastDate: widget.lastDate,
            onDateChanged: (day) => setState(() => _selected = day),
          ),
          _PickerActions(onDone: () => Navigator.of(context).pop(_selected)),
        ],
      ),
    );
  }
}

class _GlassTimeBody extends StatefulWidget {
  const _GlassTimeBody({required this.initialTime});

  final TimeOfDay initialTime;

  @override
  State<_GlassTimeBody> createState() => _GlassTimeBodyState();
}

class _GlassTimeBodyState extends State<_GlassTimeBody> {
  late TimeOfDay _selected = widget.initialTime;

  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).colorScheme.onSurface;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 216,
            child: CupertinoTheme(
              data: CupertinoThemeData(
                brightness: Theme.of(context).brightness,
                textTheme: CupertinoTextThemeData(
                  dateTimePickerTextStyle: TextStyle(
                    color: textColor,
                    fontSize: 21,
                  ),
                ),
              ),
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.time,
                use24hFormat: false,
                initialDateTime: DateTime(
                  2000,
                  1,
                  1,
                  widget.initialTime.hour,
                  widget.initialTime.minute,
                ),
                onDateTimeChanged: (value) =>
                    _selected = TimeOfDay.fromDateTime(value),
              ),
            ),
          ),
          _PickerActions(onDone: () => Navigator.of(context).pop(_selected)),
        ],
      ),
    );
  }
}

class _PickerActions extends StatelessWidget {
  const _PickerActions({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final labels = MaterialLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.s4, AppSpacing.s2, AppSpacing.s4, AppSpacing.s4),
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(labels.cancelButtonLabel),
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: FilledButton(
              onPressed: onDone,
              child: Text(labels.okButtonLabel),
            ),
          ),
        ],
      ),
    );
  }
}
