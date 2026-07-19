import 'dart:async';

import 'package:flutter/material.dart';

/// Reveals Arabic copy one complete word at a time.
///
/// Revealing full words preserves Arabic shaping while giving the calm typing
/// effect used by the first-launch story. Reduced-motion users see the complete
/// copy immediately.
class WordRevealText extends StatefulWidget {
  const WordRevealText(
    this.text, {
    super.key,
    required this.style,
    this.textAlign = TextAlign.start,
    this.initialDelay = const Duration(milliseconds: 120),
    this.wordInterval = const Duration(milliseconds: 115),
    this.showCursor = true,
    this.onComplete,
  });

  final String text;
  final TextStyle style;
  final TextAlign textAlign;
  final Duration initialDelay;
  final Duration wordInterval;
  final bool showCursor;

  /// Called once, the moment the last word becomes visible (or immediately,
  /// if reduced motion skips the reveal entirely).
  final VoidCallback? onComplete;

  @override
  State<WordRevealText> createState() => _WordRevealTextState();
}

class _WordRevealTextState extends State<WordRevealText> {
  Timer? _timer;
  Timer? _cursorTimer;
  List<String> _words = const [];
  int _visibleWords = 0;
  bool _cursorVisible = true;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _prepareWords();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didUpdateWidget(covariant WordRevealText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.wordInterval != widget.wordInterval ||
        oldWidget.initialDelay != widget.initialDelay) {
      _reset();
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  // Splitting on \s+ alone would also match embedded newlines and rejoin
  // multi-line copy (e.g. a two-line title) onto one line. Line breaks are
  // kept as their own token — revealed like a word, rendered as '\n' — so
  // intentional line breaks in the source string survive the reveal.
  static const _lineBreak = '\n';

  void _prepareWords() {
    final lines = widget.text.split('\n');
    final words = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) words.add(_lineBreak);
      words.addAll(
        lines[i].trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty),
      );
    }
    _words = words;
  }

  void _reset() {
    _timer?.cancel();
    _cursorTimer?.cancel();
    _prepareWords();
    _visibleWords = 0;
    _cursorVisible = true;
    _started = false;
  }

  void _start() {
    if (!mounted || _started) return;
    _started = true;

    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion || _words.isEmpty) {
      setState(() {
        _visibleWords = _words.length;
        _cursorVisible = false;
      });
      widget.onComplete?.call();
      return;
    }

    _cursorTimer = Timer.periodic(const Duration(milliseconds: 420), (_) {
      if (mounted) setState(() => _cursorVisible = !_cursorVisible);
    });
    _timer = Timer(widget.initialDelay, _revealNextWord);
  }

  void _revealNextWord() {
    if (!mounted || _visibleWords >= _words.length) return;
    setState(() => _visibleWords++);
    if (_visibleWords < _words.length) {
      _timer = Timer(widget.wordInterval, _revealNextWord);
    } else {
      widget.onComplete?.call();
      _timer = Timer(const Duration(milliseconds: 850), () {
        _cursorTimer?.cancel();
        if (mounted) setState(() => _cursorVisible = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cursorTimer?.cancel();
    super.dispose();
  }

  String _composeVisibleText() {
    final buffer = StringBuffer();
    for (final token in _words.take(_visibleWords)) {
      if (token == _lineBreak) {
        buffer.write('\n');
      } else {
        if (buffer.isNotEmpty && !buffer.toString().endsWith('\n')) {
          buffer.write(' ');
        }
        buffer.write(token);
      }
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final visibleText = _composeVisibleText();
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: visibleText),
          if (widget.showCursor && _cursorVisible)
            TextSpan(
              text: ' |',
              style: widget.style.copyWith(
                color: const Color(0xFFF4C84B),
                fontWeight: FontWeight.w400,
              ),
            ),
        ],
      ),
      textAlign: widget.textAlign,
      style: widget.style,
    );
  }
}
