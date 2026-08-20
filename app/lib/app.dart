import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import 'core/router/app_router.dart';
import 'core/security/app_lock_gate.dart';
import 'features/app/app_boot_loader.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_mode_controller.dart';
import 'core/i18n/locale_provider.dart';

/// جذر التطبيق. Arabic-first / RTL.
class MoneyApp extends ConsumerWidget {
  const MoneyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeLocale = ref.watch(localeProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'قرش',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: appRouter,
      scrollBehavior:
          const MaterialScrollBehavior().copyWith(scrollbars: false),

      // تدويل اللغة والاتجاهات ديناميكياً
      locale: activeLocale,
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            // The user's system text size is RESPECTED, bounded to the range
            // the financial layouts are verified against (see the 1.25x
            // overflow tests). Never a fixed scale — that would silently
            // disable Dynamic Type for everyone.
            textScaler: mediaQuery.textScaler.clamp(
              minScaleFactor: 0.8,
              maxScaleFactor: 1.25,
            ),
          ),
          // Root-level restore loader: one continuous branded screen from
          // launch to data-ready (see [appDataRestoring]) — sits above the
          // router so the shell never flashes reseeded defaults behind it.
          child: Stack(
            children: [
              AppLockGate(child: child!),
              ValueListenableBuilder<bool>(
                valueListenable: appDataRestoring,
                builder: (context, restoring, _) => restoring
                    ? const Positioned.fill(child: AppBootLoader())
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      },
    );
  }
}
