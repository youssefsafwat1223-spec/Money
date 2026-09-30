import 'bank_profile.dart';

/// Resolves a free-form bank suggestion (e.g. from AI discovery) onto an
/// EXISTING catalog [BankProfile]. Pure and deterministic: it never invents a
/// bank, and an ambiguous or unknown suggestion resolves to null. A profile
/// name/keyword matches when it equals a contiguous run of whole words of the
/// suggested name (compact-normalized).
class BankInstitutionMatcher {
  const BankInstitutionMatcher._();

  static const int _minTokenLength = 3;

  static String _compact(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9؀-ۿ]+'), '');

  static BankProfile? match({
    String? bankKeySuggestion,
    required String suggestedBankName,
    String? country,
    List<BankProfile> availableProfiles = const [],
  }) {
    final key = bankKeySuggestion?.trim();
    if (key != null && key.isNotEmpty) {
      final exact = BankProfiles.findByKey(
        key,
        extraProfiles: availableProfiles,
      );
      if (exact != null) return exact;
    }

    final words = suggestedBankName
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9\u0600-\u06ff]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return null;
    // Every contiguous run of whole words, compacted. Matching on word
    // boundaries keeps a short keyword such as `nbe` from matching inside
    // `QNB Egypt` (q-nbe-gypt).
    final runs = <String>{};
    for (var i = 0; i < words.length; i++) {
      final buffer = StringBuffer();
      for (var j = i; j < words.length; j++) {
        buffer.write(words[j]);
        runs.add(buffer.toString());
      }
    }
    final wantedCountry = country?.trim().toUpperCase();

    // availableProfiles win over built-ins that share a key.
    final byKey = <String, BankProfile>{};
    for (final profile in [...BankProfiles.all, ...availableProfiles]) {
      byKey[profile.bankKey] = profile;
    }

    final candidates = <BankProfile>[];
    for (final profile in byKey.values) {
      final profileCountry = profile.country?.trim().toUpperCase();
      if (wantedCountry != null &&
          wantedCountry.isNotEmpty &&
          profileCountry != null &&
          profileCountry.isNotEmpty &&
          profileCountry != wantedCountry) {
        continue;
      }
      final matches = [profile.displayName, ...profile.keywords].any((token) {
        final compact = _compact(token);
        return compact.length >= _minTokenLength && runs.contains(compact);
      });
      if (matches) candidates.add(profile);
    }
    return candidates.length == 1 ? candidates.single : null;
  }
}
