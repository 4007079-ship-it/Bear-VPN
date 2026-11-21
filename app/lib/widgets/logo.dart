import 'package:flutter/material.dart';

/// Название приложения — в одном месте.
const appName = 'Shadow VPN';

/// Знак Shadow VPN: мятная молния на графитовой плашке.
class AppLogo extends StatelessWidget {
  final double size;

  /// С плашкой (как иконка приложения) или только молния.
  final bool tile;
  const AppLogo({super.key, this.size = 32, this.tile = true});

  static const mint = Color(0xFF3DDC97);
  static const graphite = Color(0xFF1B2024);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: appName,
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _BoltPainter(tile: tile),
      ),
    );
  }
}

class _BoltPainter extends CustomPainter {
  final bool tile;
  _BoltPainter({required this.tile});

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 100;
    if (tile) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(24 * k)),
        Paint()..color = AppLogo.graphite,
      );
    }
    // Та же молния, что в app/branding/shadow_icon.svg.
    final bolt = Path()
      ..moveTo(58 * k, 10 * k)
      ..lineTo(26 * k, 56 * k)
      ..lineTo(46 * k, 56 * k)
      ..lineTo(40 * k, 90 * k)
      ..lineTo(74 * k, 42 * k)
      ..lineTo(54 * k, 42 * k)
      ..lineTo(62 * k, 10 * k)
      ..close();
    final paint = Paint()
      ..color = AppLogo.mint
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 3 * k;
    canvas.drawPath(bolt, paint..style = PaintingStyle.fill);
    canvas.drawPath(bolt, paint..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant _BoltPainter old) => old.tile != tile;
}
