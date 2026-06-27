/// Payment aggregators / gateways (Fawry and the like) are intermediaries, not
/// the real merchant. A bank SMS often reads "Fawry <merchant>", so the gateway
/// name leaks in as the merchant — wrongly forcing a "bills" category and
/// showing the gateway's logo. We strip the gateway prefix so the underlying
/// merchant drives categorization and the brand logo; when there is no
/// underlying merchant we at least suppress the gateway's own logo
/// (see [isAggregator]).
class PaymentAggregators {
  PaymentAggregators._();

  /// Normalized (uppercase) gateway tokens. Extend as new ones surface.
  static const Set<String> _gateways = {
    'FAWRY',
    'FAWATEER',
    'FAWATEERAK',
  };

  static final RegExp _leadingSeparators = RegExp(r'^[\s*\-_:#/.]+');

  /// Returns the underlying merchant: if [raw] leads with a known gateway
  /// followed by a separator, drops the gateway and returns the rest; otherwise
  /// returns [raw] unchanged (including a bare gateway name with nothing after).
  static String? resolveMerchant(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return raw;
    final upper = trimmed.toUpperCase();
    for (final gateway in _gateways) {
      if (!upper.startsWith(gateway)) continue;
      final after = trimmed.substring(gateway.length);
      if (after.isEmpty) return raw; // bare gateway, no merchant to extract
      // Require a separator so "FAWRYZONE" isn't mistaken for "Fawry · ZONE".
      if (!_leadingSeparators.hasMatch(after)) continue;
      final cleaned = after.replaceFirst(_leadingSeparators, '').trim();
      return cleaned.isEmpty ? raw : cleaned;
    }
    return raw;
  }

  /// True when [name] is *exactly* a gateway (no underlying merchant) — used to
  /// suppress the gateway's own brand logo.
  static bool isAggregator(String? name) {
    if (name == null) return false;
    return _gateways.contains(name.trim().toUpperCase());
  }
}
