import 'package:drift/drift.dart';

import '../../domain/usecases/user_settings_usecases.dart';
import '../db/app_database.dart';
import 'catalog_daos.dart';

class GrowthCampaignService {
  GrowthCampaignService({
    required AppDatabase database,
    required RemoteGrowthCampaignsDao dao,
    required LoadNotificationPreferencesUseCase loadPreferences,
    required SaveNotificationPreferencesUseCase savePreferences,
    DateTime Function()? now,
  })  : _database = database,
        _dao = dao,
        _loadPreferences = loadPreferences,
        _savePreferences = savePreferences,
        _now = now ?? (() => DateTime.now().toUtc());

  final AppDatabase _database;
  final RemoteGrowthCampaignsDao _dao;
  final LoadNotificationPreferencesUseCase _loadPreferences;
  final SaveNotificationPreferencesUseCase _savePreferences;
  final DateTime Function() _now;

  Future<List<RemoteGrowthCampaign>> visibleDashboardBanners() async {
    final campaigns = await _dao.getActiveByType('dashboard_banner');
    if (campaigns.isEmpty) return const [];
    final preferences = await _loadPreferences();
    final profile = await _readProfile();
    final now = _now();
    return campaigns.where((campaign) {
      final inbox = preferences.inboxState;
      if (inbox.hasDismissed(campaign.id)) return false;
      if (campaign.oncePerUser && inbox.impressionsFor(campaign.id) > 0) {
        return false;
      }
      final max = campaign.maxImpressions;
      if (max != null && inbox.impressionsFor(campaign.id) >= max) {
        return false;
      }
      final lastSent = inbox.lastSentFor(campaign.id);
      if (lastSent != null &&
          now.difference(lastSent).inHours < campaign.cooldownHours) {
        return false;
      }
      return _matchesSegment(campaign.targetSegment, profile);
    }).toList();
  }

  Future<void> recordImpression(String id) async {
    final preferences = await _loadPreferences();
    await _savePreferences(
      preferences.copyWith(
        inboxState: preferences.inboxState.markImpression(id),
      ),
    );
  }

  Future<void> dismiss(String id) async {
    final preferences = await _loadPreferences();
    await _savePreferences(
      preferences.copyWith(
        inboxState: preferences.inboxState.markDismissed(id),
      ),
    );
  }

  bool _matchesSegment(String segment, _CampaignProfile profile) {
    switch (segment) {
      case 'all':
        return true;
      case 'new_user':
      case 'no_shortcut':
        return profile.transactionCount == 0;
      case 'has_first_transaction':
        return profile.transactionCount >= 1;
      case 'inactive_3_days':
        final last = profile.lastTransactionAt;
        return last != null && _now().difference(last).inDays >= 3;
      case 'active_user':
        final last = profile.lastTransactionAt;
        return last != null && _now().difference(last).inDays < 3;
      case 'budget_user':
        return profile.budgetCount > 0;
      default:
        return true;
    }
  }

  Future<_CampaignProfile> _readProfile() async {
    final tx = await _database.customSelect(
      '''
        SELECT COUNT(*) AS transaction_count, MAX(created_at) AS last_transaction_at
        FROM transactions
        WHERE status != ?;
      ''',
      variables: [Variable.withString('ignored')],
    ).getSingle();
    final budgets = await _database
        .customSelect('SELECT COUNT(*) AS budget_count FROM budgets;')
        .getSingle();
    final lastRaw = tx.readNullable<String>('last_transaction_at');
    return _CampaignProfile(
      transactionCount: tx.read<int>('transaction_count'),
      budgetCount: budgets.read<int>('budget_count'),
      lastTransactionAt:
          lastRaw == null ? null : DateTime.tryParse(lastRaw)?.toUtc(),
    );
  }
}

class _CampaignProfile {
  const _CampaignProfile({
    required this.transactionCount,
    required this.budgetCount,
    required this.lastTransactionAt,
  });

  final int transactionCount;
  final int budgetCount;
  final DateTime? lastTransactionAt;
}
