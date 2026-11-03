// Read-only status refresh of the actual public privacy screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/features/settings/consent_status.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';

final _events = <String, int>{};
Map<String, int> visualParityPrivacyRefreshEvents() => Map.unmodifiable(_events);

class PrivacyRefreshReview extends StatelessWidget {
  const PrivacyRefreshReview({super.key});
  @override
  Widget build(BuildContext context) => ProviderScope(
        overrides: [
          // A view-only stored-choice input; it is never persisted or used to
          // construct a consent capability. The uncertain facts keep it unknown.
          userSettingsProvider.overrideWith((ref) async {
            final settings = await ref.read(userSettingsRepositoryProvider).getSettings();
            return settings.copyWith(cloudConsentState: ConsentState.accepted,
                aiConsentState: ConsentState.accepted);
          }),
          consentLiveFactsProvider.overrideWith((ref) async {
            _events.update('reads', (n) => n + 1, ifAbsent: () => 1);
            return ConsentLiveFacts.unreadable;
          }),
        ],
        child: const PrivacyScreen(),
      );
}
