import 'package:drift/drift.dart';

import '../../data/db/app_database.dart';
import 'coupon_models.dart';

/// How an offer's link was opened.
enum ClickOutcome {
  /// A tracked link. We minted a click and hold a claim token for it.
  tracked,

  /// The plain merchant URL. The user reaches the offer; we do not earn on it.
  untracked,

  /// Nothing to open. The offer has no URL at all.
  unavailable,
}

class ClickResult {
  const ClickResult(this.outcome, {this.url, this.clickId});

  final ClickOutcome outcome;
  final String? url;
  final String? clickId;
}

/// A stored click receipt — the device's half of an anonymous click.
class ClickReceipt {
  const ClickReceipt({
    required this.clickId,
    required this.claimToken,
    required this.couponId,
    required this.launchedAt,
    required this.expiresAt,
    required this.lastStatus,
    this.merchantId,
  });

  final String clickId;

  /// The PLAINTEXT token. The server holds only its SHA-256, so this row is the
  /// only thing in existence that can prove this click was ours — which is
  /// exactly what lets attribution work without the server knowing whose clicks
  /// are whose.
  final String claimToken;

  final String couponId;
  final String? merchantId;
  final DateTime launchedAt;
  final DateTime expiresAt;
  final String lastStatus;
}

/// The device's affiliate click path.
///
/// ## The degradation ladder
///
/// Tracking is a revenue optimisation. The user's ability to reach the offer is
/// the product. Whenever those two conflict, the product wins:
///
///   1. flag off, no consent, endpoint down, rate-limited, network error,
///      malformed response → **launch the plain merchant URL, untracked**;
///   2. no URL at all → nothing to open, and the caller shows the code instead.
///
/// There is no path where a tracking failure stops someone using a coupon. That
/// would be trading the user's purchase for our commission, which is the wrong
/// trade in both directions: they lose the discount and we earn nothing anyway.
class AffiliateClickGateway {
  const AffiliateClickGateway({
    required AppDatabase database,
    required Future<Map<String, Object?>?> Function(Map<String, Object?> body)
        prepareClick,
    required bool Function() trackingEnabled,
  })  : _db = database,
        _prepareClick = prepareClick,
        _trackingEnabled = trackingEnabled;

  final AppDatabase _db;

  /// Calls `prepare-affiliate-click`. Returns null on ANY failure — the caller
  /// cannot distinguish a network error from a refusal, and does not need to,
  /// because the response to both is identical.
  final Future<Map<String, Object?>?> Function(Map<String, Object?> body) _prepareClick;

  /// `enable_affiliate_links` AND cloud consent, decided by the caller. Checked
  /// before anything else so a disabled build makes no request at all.
  final bool Function() _trackingEnabled;

  Future<ClickResult> open(CouponOffer offer, {String surface = 'unknown'}) async {
    final fallbackUrl = offer.partnerUrl;
    if (fallbackUrl == null || fallbackUrl.isEmpty) {
      return const ClickResult(ClickOutcome.unavailable);
    }
    if (!_trackingEnabled()) {
      return ClickResult(ClickOutcome.untracked, url: fallbackUrl);
    }

    Map<String, Object?>? response;
    try {
      response = await _prepareClick({'coupon_id': offer.id, 'surface': surface});
    } catch (_) {
      // Deliberately swallowed. A tracking failure is not something the user
      // should see, and it must not delay the tap either.
      response = null;
    }

    if (response == null || response['tracked'] != true) {
      // Includes the legitimate case: this offer is not an affiliate offer, and
      // the server said so.
      final serverUrl = response?['url'];
      return ClickResult(
        ClickOutcome.untracked,
        url: serverUrl is String && serverUrl.startsWith('https://')
            ? serverUrl
            : fallbackUrl,
      );
    }

    final url = response['url'];
    final clickId = response['click_id'];
    final token = response['claim_token'];
    if (url is! String || !url.startsWith('https://') ||
        clickId is! String || token is! String) {
      // A malformed tracked response. Never open a non-https URL the server
      // handed us — a tracked click that downgrades the connection is worse
      // than an untracked one.
      return ClickResult(ClickOutcome.untracked, url: fallbackUrl);
    }

    // Persist BEFORE returning the URL. If the app dies between launching the
    // browser and writing the receipt, the click exists server-side with no
    // token on the device — permanently unclaimable, and the user would never
    // get credit for a purchase they made.
    try {
      await _storeReceipt(
        clickId: clickId,
        claimToken: token,
        couponId: offer.id,
        merchantId: offer.merchantId,
      );
    } catch (_) {
      // If we cannot keep our half, the click is unclaimable anyway. Fall back
      // rather than sending the user through a tracked link we can never
      // reconcile — that would attribute a sale we cannot credit them for.
      return ClickResult(ClickOutcome.untracked, url: fallbackUrl);
    }

    return ClickResult(ClickOutcome.tracked, url: url, clickId: clickId);
  }

  Future<void> _storeReceipt({
    required String clickId,
    required String claimToken,
    required String couponId,
    String? merchantId,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.customInsert(
      '''
        INSERT INTO affiliate_click_receipts(
          click_id, claim_token, coupon_id, merchant_id,
          launched_at, last_status, expires_at
        ) VALUES (?, ?, ?, ?, ?, 'pending', ?)
        ON CONFLICT(click_id) DO NOTHING;
      ''',
      variables: [
        Variable.withString(clickId),
        Variable.withString(claimToken),
        Variable.withString(couponId),
        if (merchantId == null) const Variable<String>(null) else Variable.withString(merchantId),
        Variable.withString(now.toIso8601String()),
        // Mirrors the server's 90-day window. A receipt outliving its click is
        // a token that can only ever return `unknown`, and polling it forever
        // spends the user's battery to learn nothing.
        Variable.withString(now.add(const Duration(days: 90)).toIso8601String()),
      ],
    );
  }

  /// Receipts still worth asking about: pending, and not yet expired.
  Future<List<ClickReceipt>> pendingReceipts({int limit = 20}) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM affiliate_click_receipts
         WHERE last_status = 'pending' AND expires_at > ?
         ORDER BY launched_at DESC LIMIT ?;
      ''',
      variables: [
        Variable.withString(DateTime.now().toUtc().toIso8601String()),
        Variable.withInt(limit),
      ],
    ).get();
    return rows.map(_fromRow).toList();
  }

  Future<void> recordStatus(String clickId, String status) async {
    await _db.customUpdate(
      'UPDATE affiliate_click_receipts SET last_status = ?, last_checked_at = ? '
      'WHERE click_id = ?;',
      variables: [
        Variable.withString(status),
        Variable.withString(DateTime.now().toUtc().toIso8601String()),
        Variable.withString(clickId),
      ],
    );
  }

  /// Drops expired receipts.
  ///
  /// An expired receipt is a credential that can no longer be used for
  /// anything, so keeping it is retention with no purpose — and this one holds a
  /// plaintext token.
  Future<int> pruneExpired() async {
    return _db.customUpdate(
      'DELETE FROM affiliate_click_receipts WHERE expires_at <= ?;',
      variables: [Variable.withString(DateTime.now().toUtc().toIso8601String())],
    );
  }

  static ClickReceipt _fromRow(QueryRow r) => ClickReceipt(
        clickId: r.read<String>('click_id'),
        claimToken: r.read<String>('claim_token'),
        couponId: r.read<String>('coupon_id'),
        merchantId: r.readNullable<String>('merchant_id'),
        launchedAt: DateTime.parse(r.read<String>('launched_at')),
        expiresAt: DateTime.parse(r.read<String>('expires_at')),
        lastStatus: r.read<String>('last_status'),
      );
}
