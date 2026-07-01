import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../session/app_session.dart';
import '../../features/accounts/accounts_screen.dart';
import '../../features/achievements/achievements_screen.dart';
import '../../features/announcements/announcements_screen.dart';
import '../../features/app/app_shell.dart';
import '../../features/backup/backup_screen.dart';
import '../../features/onboarding/first_transaction_screen.dart';
import '../../features/onboarding/ios_shortcut_screen.dart';
import '../../features/onboarding/listening_screen.dart';
import '../../features/onboarding/luxe_onboarding_screen.dart';
import '../../features/onboarding/method_screen.dart';
import '../../features/onboarding/otp_screen.dart';
import '../../features/onboarding/restore_prompt_screen.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/settings/privacy_screen.dart';
import '../../features/onboarding/capture_method_picker_screen.dart';
import '../../features/subscriptions/subscriptions_screen.dart';
import '../../features/budgets/budget_form_screen.dart';
import '../../features/budgets/budgets_screen.dart';
import '../../features/cards/card_details_screen.dart';
import '../../features/capture/manual_paste_screen.dart';
import '../../features/capture/sms_permission_screen.dart';
import '../../features/coupons/coupons_screen.dart';
import '../../features/goals/goal_details_screen.dart';
import '../../features/goals/goal_form_screen.dart';
import '../../features/goals/goals_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/transactions/transaction_details_screen.dart';

String onboardingEntryPathForSession(AppSession session) {
  return session.hasCompletedOnboarding ? '/onboarding/auth' : '/onboarding';
}

/// موجّه التطبيق (go_router).
final appRouter = GoRouter(
  initialLocation: '/',
  refreshListenable: AppSession.instance,
  redirect: (context, state) {
    final status = AppSession.instance.status;
    final inOnboarding = state.matchedLocation.startsWith('/onboarding');
    final guestUpgrade = AppSession.instance.isGuest &&
        (state.matchedLocation == '/onboarding/auth' ||
            state.matchedLocation == '/onboarding/otp');
    if (status == SessionStatus.needsOnboarding && !inOnboarding) {
      return onboardingEntryPathForSession(AppSession.instance);
    }
    if (status == SessionStatus.authenticated &&
        inOnboarding &&
        !guestUpgrade) {
      return '/';
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) => const AppShell(),
    ),
    GoRoute(
      path: '/onboarding',
      name: 'onboarding',
      builder: (context, state) => const LuxeOnboardingScreen(),
    ),
    GoRoute(
      path: '/onboarding/auth',
      name: 'onboarding-auth',
      builder: (context, state) => const LuxeOnboardingScreen(skipStory: true),
    ),
    GoRoute(
      path: '/onboarding/setup',
      name: 'onboarding-setup',
      builder: (context, state) => const LuxeOnboardingScreen(
        skipStory: true,
        initialPage: 1,
      ),
    ),
    GoRoute(
      path: '/onboarding/privacy',
      name: 'onboarding-privacy',
      builder: (context, state) => const PrivacyScreen(),
    ),
    GoRoute(
      path: '/onboarding/method-picker',
      name: 'onboarding-method-picker',
      builder: (context, state) => const CaptureMethodPickerScreen(),
    ),
    GoRoute(
      path: '/onboarding/manual',
      name: 'onboarding-manual',
      builder: (context, state) => const ManualPasteScreen(),
    ),
    GoRoute(
      path: '/onboarding/method',
      name: 'onboarding-method',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const OnboardingMethodScreen(),
        opaque: false,
        barrierDismissible: false,
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(
              opacity: curved,
              child: child,
            ),
          );
        },
      ),
    ),
    GoRoute(
      path: '/onboarding/restore',
      name: 'onboarding-restore',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const RestorePromptScreen(onboardingFlow: true),
        opaque: false,
        barrierDismissible: false,
        barrierColor: Colors.black26,
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(opacity: curved, child: child),
          );
        },
      ),
    ),
    GoRoute(
      path: '/onboarding/ios-shortcut',
      name: 'onboarding-ios-shortcut',
      builder: (context, state) => const IosShortcutScreen(),
    ),
    GoRoute(
      path: '/onboarding/listening',
      name: 'onboarding-listening',
      builder: (context, state) => const ListeningScreen(),
    ),
    GoRoute(
      path: '/onboarding/first-transaction',
      name: 'onboarding-first-transaction',
      builder: (context, state) => FirstTransactionScreen(
        transactionId: state.extra as String? ?? '',
      ),
    ),
    GoRoute(
      path: '/onboarding/otp',
      name: 'onboarding-otp',
      builder: (context, state) =>
          OtpScreen(email: state.extra as String? ?? ''),
    ),
    GoRoute(
      path: '/backup',
      name: 'backup',
      builder: (context, state) => const BackupScreen(),
    ),
    GoRoute(
      path: '/backup/restore',
      name: 'backup-restore',
      builder: (context, state) =>
          const RestorePromptScreen(onboardingFlow: false),
    ),
    GoRoute(
      path: '/privacy',
      name: 'privacy',
      builder: (context, state) => const PrivacyScreen(),
    ),
    GoRoute(
      path: '/reports',
      name: 'reports',
      builder: (context, state) => const ReportsScreen(),
    ),
    GoRoute(
      path: '/accounts',
      name: 'accounts',
      builder: (context, state) => const AccountsScreen(),
    ),
    GoRoute(
      path: '/announcements',
      name: 'announcements',
      builder: (context, state) => const AnnouncementsScreen(),
    ),
    GoRoute(
      path: '/subscriptions',
      name: 'subscriptions',
      builder: (context, state) => const SubscriptionsScreen(),
    ),
    GoRoute(
      path: '/coupons',
      name: 'coupons',
      builder: (context, state) => const CouponsScreen(),
    ),
    GoRoute(
      path: '/paste',
      name: 'paste',
      builder: (context, state) => const ManualPasteScreen(),
    ),
    GoRoute(
      path: '/capture/sms-permission',
      name: 'sms-permission',
      builder: (context, state) => const SmsPermissionScreen(),
    ),
    GoRoute(
      path: '/transaction/:id',
      name: 'transaction',
      builder: (context, state) =>
          TransactionDetailsScreen(transactionId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/card/:last4',
      name: 'card',
      builder: (context, state) =>
          CardDetailsScreen(last4: state.pathParameters['last4']!),
    ),
    GoRoute(
      path: '/budgets',
      name: 'budgets',
      builder: (context, state) => const BudgetsScreen(),
    ),
    GoRoute(
      path: '/budgets/new',
      name: 'budget-new',
      builder: (context, state) => const BudgetFormScreen(),
    ),
    GoRoute(
      path: '/budgets/:id/edit',
      name: 'budget-edit',
      builder: (context, state) => BudgetFormScreen(
        budgetId: state.pathParameters['id'],
      ),
    ),
    GoRoute(
      path: '/goals',
      name: 'goals',
      builder: (context, state) => const GoalsScreen(),
    ),
    GoRoute(
      path: '/goals/new',
      name: 'goal-new',
      builder: (context, state) => const GoalFormScreen(),
    ),
    GoRoute(
      path: '/goals/:id',
      name: 'goal-details',
      builder: (context, state) => GoalDetailsScreen(
        goalId: state.pathParameters['id']!,
      ),
    ),
    GoRoute(
      path: '/achievements',
      name: 'achievements',
      builder: (context, state) => const AchievementsScreen(),
    ),
    GoRoute(
      path: '/settings',
      name: 'settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/profile',
      name: 'profile',
      builder: (context, state) => const SettingsScreen(),
    ),
  ],
);
