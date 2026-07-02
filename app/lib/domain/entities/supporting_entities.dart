class AchievementEntity {
  const AchievementEntity({
    required this.id,
    required this.key,
    required this.nameAr,
    required this.progress,
    this.unlockedAt,
  });

  final String id;
  final String key;
  final String nameAr;
  final DateTime? unlockedAt;
  final double progress;

  AchievementEntity copyWith({
    String? id,
    String? key,
    String? nameAr,
    DateTime? unlockedAt,
    double? progress,
  }) {
    return AchievementEntity(
      id: id ?? this.id,
      key: key ?? this.key,
      nameAr: nameAr ?? this.nameAr,
      unlockedAt: unlockedAt ?? this.unlockedAt,
      progress: progress ?? this.progress,
    );
  }
}

class StreakEntity {
  const StreakEntity({
    required this.id,
    required this.currentStreak,
    required this.longestStreak,
    required this.lastActiveDate,
    required this.freezesAvailable,
  });

  final String id;
  final int currentStreak;
  final int longestStreak;
  final DateTime lastActiveDate;
  final int freezesAvailable;

  StreakEntity copyWith({
    String? id,
    int? currentStreak,
    int? longestStreak,
    DateTime? lastActiveDate,
    int? freezesAvailable,
  }) {
    return StreakEntity(
      id: id ?? this.id,
      currentStreak: currentStreak ?? this.currentStreak,
      longestStreak: longestStreak ?? this.longestStreak,
      lastActiveDate: lastActiveDate ?? this.lastActiveDate,
      freezesAvailable: freezesAvailable ?? this.freezesAvailable,
    );
  }
}

class XpLevelEntity {
  const XpLevelEntity({
    required this.id,
    required this.totalXp,
    required this.level,
    required this.levelKey,
  });

  final String id;
  final int totalXp;
  final int level;
  final String levelKey;

  XpLevelEntity copyWith({
    String? id,
    int? totalXp,
    int? level,
    String? levelKey,
  }) {
    return XpLevelEntity(
      id: id ?? this.id,
      totalXp: totalXp ?? this.totalXp,
      level: level ?? this.level,
      levelKey: levelKey ?? this.levelKey,
    );
  }
}

class SubscriptionEntity {
  const SubscriptionEntity({
    required this.id,
    required this.merchantId,
    required this.amount,
    required this.period,
    required this.isConfirmed,
    required this.reminderOn,
    this.nextDueDate,
  });

  final String id;
  final String merchantId;
  final double amount;
  final String period;
  final DateTime? nextDueDate;
  final bool isConfirmed;
  final bool reminderOn;
}

class ParsingRuleEntity {
  const ParsingRuleEntity({
    required this.id,
    required this.bankKey,
    required this.locale,
    required this.pattern,
    required this.field,
    required this.priority,
    required this.version,
    required this.isActive,
  });

  final String id;
  final String bankKey;
  final String locale;
  final String pattern;
  final String field;
  final int priority;
  final int version;
  final bool isActive;
}

class UserSettingsEntity {
  const UserSettingsEntity({
    required this.id,
    required this.country,
    required this.currency,
    required this.language,
    required this.theme,
    required this.inputMethod,
    required this.notificationsJson,
    required this.dbEncryptionKeyRef,
    required this.privacyModeEnabled,
    this.displayName,
    this.phoneNumber,
    this.avatarPath,
    this.dateOfBirth,
    // opt-in: تُسأل صراحةً في الـ onboarding (مرحلة موافقة الذكاء الاصطناعي).
    this.aiConsentGranted = false,
  });

  final String id;
  final String? displayName;
  final String? phoneNumber;
  final String? avatarPath;
  final DateTime? dateOfBirth;
  final String country;
  final String currency;
  final String language;
  final String theme;
  final String inputMethod;
  final String notificationsJson;
  final String dbEncryptionKeyRef;
  final bool privacyModeEnabled;

  /// User has opted in to AI suggestions (off by default).
  /// When true, low-confidence messages may be sent (sanitized) to an AI
  /// service for parsing or merchant categorization.
  final bool aiConsentGranted;

  UserSettingsEntity copyWith({
    String? id,
    String? country,
    String? currency,
    String? language,
    String? theme,
    String? inputMethod,
    String? notificationsJson,
    String? dbEncryptionKeyRef,
    bool? privacyModeEnabled,
    String? displayName,
    String? phoneNumber,
    String? avatarPath,
    DateTime? dateOfBirth,
    bool? aiConsentGranted,
  }) {
    return UserSettingsEntity(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      avatarPath: avatarPath ?? this.avatarPath,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      country: country ?? this.country,
      currency: currency ?? this.currency,
      language: language ?? this.language,
      theme: theme ?? this.theme,
      inputMethod: inputMethod ?? this.inputMethod,
      notificationsJson: notificationsJson ?? this.notificationsJson,
      dbEncryptionKeyRef: dbEncryptionKeyRef ?? this.dbEncryptionKeyRef,
      privacyModeEnabled: privacyModeEnabled ?? this.privacyModeEnabled,
      aiConsentGranted: aiConsentGranted ?? this.aiConsentGranted,
    );
  }
}
