import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

class AppLoadingState extends StatelessWidget {
  const AppLoadingState({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: c.cta),
          if (label != null) ...[
            const SizedBox(height: 16),
            Text(label!, style: TextStyle(color: c.textMuted)),
          ],
        ],
      ),
    );
  }
}
