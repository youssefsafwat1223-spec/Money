import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../session/app_session.dart';
import '../../features/accounts/accounts_screen.dart';
import '../../features/achievements/achievements_screen.dart';
import '../../features/announcements/announcements_screen.dart';
import '../../features/app/app_shell.dart';
import '../../features/onboarding/auth_screen.dart';
import '../../features/onboarding/brand_screen.dart';
import '../../features/onboarding/restore_prompt_screen.dart';
import '../../features/onboarding/setup_screen.dart';
import '../../features/onboarding/story_screen.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/settings/privacy_screen.dart';
import '../../features/settings/data_transfer_screen.dart';
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
  // Only ever consulted after the welcome/story gate has been passed, so the
  // signed-out returning user lands directly on mandatory auth.
  return '/onboarding/auth';
}

/// موجّه التطبيق (go_router).
final appRouter = GoRouter(
  initialLocation: '/',
  refreshListenable: AppSession.instance,
  redirect: (context, state) {
    final session = AppSession.instance;
    final status = session.status;
    final inWelcome = state.matchedLocation == '/welcome';
    final inOnboarding = state.matchedLocation.startsWith('/onboarding');
    if (!session.hasSeenWelcomeManifesto) {
      // The cinematic sequence spans /welcome (story) → /onboarding/brand, and
      // the welcome-seen flag is only set at the end (brand's CTA), so allow the
      // brand route through the pre-welcome gate too.
      final inWelcomeFlow =
          inWelcome || state.matchedLocation == '/onboarding/brand';
      return inWelcomeFlow ? null : '/welcome';
    }
    if (inWelcome) {
      return status == SessionStatus.authenticated
          ? '/'
          : onboardingEntryPathForSession(session);
    }
    // needsOnboarding (never/not-yet authenticated) and sessionExpired (was
    // authenticated; the live Supabase session is no longer valid) both send
    // a non-guest user to the same mandatory sign-in screen. Once there,
    // `inOnboarding` is true, so this same check does not fire again on the
    // next redirect evaluation — no loop, exactly one hop per status change.
    if ((status == SessionStatus.needsOnboarding ||
            status == SessionStatus.sessionExpired) &&
        !inOnboarding) {
      if (status == SessionStatus.sessionExpired && kDebugMode) {
        debugPrint(
          '[AppSession] router redirecting to sign-in: session expired',
        );
      }
      return onboardingEntryPathForSession(session);
    }
    if (status == SessionStatus.authenticated && inOnboarding) {
      return '/';
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/welcome',
      name: 'welcome-story',
      builder: (context, state) => const OnboardingStoryScreen(),
    ),
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) => const AppShell(),
    ),
    GoRoute(
      path: '/onboarding/brand',
      name: 'onboarding-brand',
      builder: (context, state) => const OnboardingBrandScreen(),
    ),
    GoRoute(
      path: '/onboarding/auth',
      name: 'onboarding-auth',
      builder: (context, state) => const OnboardingAuthScreen(),
    ),
    GoRoute(
      path: '/onboarding/setup',
      name: 'onboarding-setup',
      builder: (context, state) => const OnboardingSetupScreen(),
    ),
    GoRoute(
      path: '/onboarding/privacy',
      name: 'onboarding-privacy',
      builder: (context, state) => const PrivacyScreen(),
    ),
    GoRoute(
      path: '/data-transfer',
      name: 'data-transfer',
      builder: (context, state) => DataTransferScreen(
        initialAction: state.uri.queryParameters['intent'],
      ),
    ),
    GoRoute(
      path: '/backup',
      name: 'backup',
      redirect: (context, state) => '/data-transfer',
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
      builder: (context, state) => SettingsScreen(
        showBackButton: context.canPop(),
      ),
    ),
    GoRoute(
      path: '/profile',
      name: 'profile',
      builder: (context, state) => SettingsScreen(
        showBackButton: context.canPop(),
      ),
    ),
  ],
);
