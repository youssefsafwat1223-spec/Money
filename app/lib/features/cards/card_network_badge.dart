import 'package:flutter/material.dart';

import '../../engine/parser/card_network.dart';
import '../../core/utils/app_lucide_icons.dart';

/// شارة شبكة البطاقة مرسومة (mada / Visa / Mastercard / Amex) — بلا أصول خارجية.
class CardNetworkBadge extends StatelessWidget {
  const CardNetworkBadge({super.key, required this.network, this.height = 22});

  final CardNetwork network;
  final double height;

  @override
  Widget build(BuildContext context) {
    switch (network) {
      case CardNetwork.mastercard:
        return SizedBox(
          height: height,
          width: height * 1.55,
          child: Stack(
            children: [
              Positioned(
                right: 0,
                child: _circle(const Color(0xFFEB001B)),
              ),
              Positioned(
                left: 0,
                child: _circle(const Color(0xFFF79E1B)),
              ),
            ],
          ),
        );
      case CardNetwork.visa:
        return _text('VISA', const Color(0xFF1A1F71), italic: true);
      case CardNetwork.mada:
        return _text('مدى', const Color(0xFF84B740));
      case CardNetwork.amex:
        return _text('AMEX', const Color(0xFF2E77BC));
      case CardNetwork.unknown:
        return Icon(AppLucideIcons.creditCard,
            size: height, color: Colors.white.withValues(alpha: 0.85));
    }
  }

  Widget _circle(Color color) => Container(
        width: height,
        height: height,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.92),
          shape: BoxShape.circle,
        ),
      );

  Widget _text(String label, Color color, {bool italic = false}) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: height * 0.62,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
