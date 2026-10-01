import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/l10n_ext.dart';
import '../accounts/account_form_sheet.dart';

/// Account Setup step. The user creates their first account through the SAME
/// form (and repository create path) as Accounts → New account; there is no
/// default account and no default name. Works offline: the create is a local
/// write that records an outbox intent.
///
/// [onDone] fires after an account is created, or when the user continues past
/// an account that already exists (upgrade mid-onboarding).
class OnboardingAccountStep extends ConsumerStatefulWidget {
  const OnboardingAccountStep({
    super.key,
    required this.currency,
    required this.onDone,
  });

  /// The currency chosen on the country step; pre-fills the form.
  final String currency;
  final VoidCallback onDone;

  @override
  ConsumerState<OnboardingAccountStep> createState() =>
      _OnboardingAccountStepState();
}

class _OnboardingAccountStepState extends ConsumerState<OnboardingAccountStep> {
  bool _adding = false;
  // A new key gives the form a fresh State (and a fresh creation id) so a
  // second account is never confused with the first; a failed save keeps the
  // same State and therefore retries with the same id.
  int _formEpoch = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
    final showList = accounts.isNotEmpty && !_adding;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s6, AppSpacing.gutter, AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            showList ? l10n.onbAccountExistingTitle : l10n.onbAccountTitle,
            style: AppTypography.sectionTitle(Colors.white),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            showList ? l10n.onbAccountExistingBody : l10n.onbAccountBody,
            style: AppTypography.body(Colors.white.withValues(alpha: 0.72)),
          ),
          const SizedBox(height: AppSpacing.s4),
          if (showList) ...[
            for (final account in accounts)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.s2),
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.s3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Row(
                    children: [
                      Icon(accountTypeIcon(account.type),
                          size: 18, color: Colors.white),
                      const SizedBox(width: AppSpacing.s2),
                      Expanded(
                        child: Text(account.name,
                            style: AppTypography.bodyStrong(Colors.white)),
                      ),
                      Text(Currency.codeWithLabel(context, account.currency),
                          style: AppTypography.caption(
                              Colors.white.withValues(alpha: 0.7))),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.s3),
            SizedBox(
              height: AppSpacing.buttonHeight,
              child: FilledButton(
                key: const ValueKey('onboarding-account-continue'),
                onPressed: widget.onDone,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppBrandBlue.brand,
                ),
                child: Text(l10n.onbAccountContinue),
              ),
            ),
            TextButton(
              key: const ValueKey('onboarding-account-add-another'),
              onPressed: () => setState(() => _adding = true),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: Text(l10n.onbAccountAddAnother),
            ),
          ] else
            navySheetTheme(Builder(
              builder: (context) => Material(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(AppRadius.md),
                clipBehavior: Clip.antiAlias,
                child: AccountFormPanel(
                  key: ValueKey('onboarding-account-form-$_formEpoch'),
                  initialCurrency: widget.currency,
                  showTitle: false,
                  onSaved: () {
                    if (!mounted) return;
                    setState(() {
                      _adding = false;
                      _formEpoch++;
                    });
                    widget.onDone();
                  },
                ),
              ),
            )),
        ],
      ),
    );
  }
}
