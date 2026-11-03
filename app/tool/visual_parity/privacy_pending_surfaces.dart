// Offline visual review of an existing scheduled-deletion presentation.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/auth/account_deletion_service.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';

final _events = <String, int>{};
Map<String, int> visualParityPrivacyPendingEvents() => Map.unmodifiable(_events);

class _RejectedCancellation implements AccountDeletionService {
  @override
  Future<AccountDeletionStatus> getStatus() async => AccountDeletionStatus(
        scheduledAt: DateTime.utc(2026, 12, 3),
      );
  @override
  Future<void> cancelDeletion() async {
    _events.update('cancelCalls', (n) => n + 1, ifAbsent: () => 1);
    throw StateError('private_synthetic_cancel_before_rpc');
  }
  @override
  Future<DateTime?> requestDeletion() =>
      throw StateError('scheduling_not_available_in_preview');
}

class PrivacyPendingReview extends StatelessWidget {
  const PrivacyPendingReview({super.key});
  @override
  Widget build(BuildContext context) => ProviderScope(
        overrides: [
          accountDeletionServiceProvider.overrideWithValue(_RejectedCancellation()),
          accountDeletionStatusProvider.overrideWith((ref) =>
              ref.watch(accountDeletionServiceProvider).getStatus()),
        ],
        child: const PrivacyScreen(),
      );
}
