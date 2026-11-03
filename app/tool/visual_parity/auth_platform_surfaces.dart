// Flutter platform-variant layout review, never imported by lib/main.dart.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:money_companion/core/auth/auth_coordinator.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/startup/automatic_session_recovery.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart';

class AuthUnsupportedReview extends StatefulWidget {
  const AuthUnsupportedReview({super.key});
  @override
  State<AuthUnsupportedReview> createState() => _AuthUnsupportedReviewState();
}

class _AuthUnsupportedReviewState extends State<AuthUnsupportedReview> {
  TargetPlatform? _previous;

  @override
  void initState() {
    super.initState();
    if (!kDebugMode || AuthCoordinator.active != null ||
        AutomaticSessionRecovery.active != null ||
        AppSession.instance.status == SessionStatus.authenticated) {
      throw StateError('platform_review_requires_no_active_session');
    }
    _previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  }

  @override
  void dispose() {
    debugDefaultTargetPlatformOverride = _previous;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const OnboardingAuthScreen();
}
