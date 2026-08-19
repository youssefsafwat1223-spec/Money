import 'package:flutter/material.dart';

import '../../engine/parser/card_network.dart';
import 'card_network_badge.dart';
import 'card_theme.dart';

/// MiniCardArt — the row-sized twin of the full card art: the same gradient
/// language via [cardGradient] and the same [CardNetworkBadge], plus a corner
/// glare — but no EMV chip and no PAN. A purely decorative leading visual so
/// a card row reads as "a card", not as a flat icon square.
class MiniCardArt extends StatelessWidget {
  const MiniCardArt({
    super.key,
    this.network = CardNetwork.unknown,
    this.themeKey,
    this.accentHex,
    this.width = 54,
  });

  final CardNetwork network;

  /// Same keys as the full card ([kCardThemes]); null = default gradient.
  final String? themeKey;
  final String? accentHex;
  final double width;

  @override
  Widget build(BuildContext context) {
    final height = width / 1.586; // real ISO/IEC 7810 card ratio
    final radius = BorderRadius.circular(width * 0.13);
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient:
            cardGradient(context, themeKey: themeKey, accentHex: accentHex),
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        children: [
          // Corner glare — the same top-corner light the full card carries.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.85, -1.1),
                  radius: 1.5,
                  colors: [
                    Colors.white.withValues(alpha: 0.26),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(width * 0.09),
            child: Align(
              alignment: AlignmentDirectional.bottomStart,
              child: CardNetworkBadge(network: network, height: width * 0.20),
            ),
          ),
        ],
      ),
    );
  }
}
