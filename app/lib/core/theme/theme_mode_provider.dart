import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// وضع الثيم الحالي (غامق/فاتح/تلقائي). يُبدَّل من الإعدادات لاحقاً.
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);
