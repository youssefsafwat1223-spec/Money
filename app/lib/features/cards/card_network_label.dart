import 'package:flutter/widgets.dart';

import '../../core/utils/l10n_ext.dart';
import '../../engine/parser/card_network.dart';

/// The display name of a card network, in the reader's language.
///
/// [CardNetwork] lives in `engine/parser`, which is pure Dart and has no
/// `BuildContext` — so it cannot look up an ARB string, and the `label` getter
/// it used to carry returned «مدى» and «بطاقة» to every reader regardless of
/// locale. Two widgets showed that directly: the card form's Network dropdown,
/// where an English user picked between "Visa", "Mastercard", "Amex" and
/// «بطاقة»; and the account-detail card row, which falls back to the network
/// name when a card has no nickname.
///
/// Same shape as `backupErrorMessage` and `importIssueMessage`: the domain type
/// stays context-free, and the mapping to words lives in the UI layer where a
/// context exists. `CardNetworkBadge` already resolved `mada` this way — only
/// the text paths were left behind.
///
/// Visa, Mastercard and Amex are brand names, spelled the same in both
/// languages, so they are literals rather than ARB keys. Putting a proper noun
/// in the ARB invites a translator to translate it.
String cardNetworkLabel(BuildContext context, CardNetwork network) {
  return switch (network) {
    CardNetwork.mada => context.l10n.cardNetworkMada,
    CardNetwork.visa => 'Visa',
    CardNetwork.mastercard => 'Mastercard',
    CardNetwork.amex => 'Amex',
    CardNetwork.unknown => context.l10n.cardNetworkGeneric,
  };
}
