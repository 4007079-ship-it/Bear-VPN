import 'package:flutter/material.dart';

/// Знак «Тень»: затмение — мятный круг, наполовину закрытый тенью.
class TenLogo extends StatelessWidget {
  final double size;

  /// С фоном-плашкой (как иконка приложения) или только знак.
  final bool tile;
  const TenLogo({super.key, this.size = 32, this.tile = true});

  static const mint = Color(0xFF3DDC97);
  static const graphite = Color(0xFF1B2024);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Тень',
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _EclipsePainter(
          tile: tile,
          shadow: tile ? graphite : Theme.of(context).scaffoldBackgroundColor,
        ),
      ),
    );
  }
}

class _EclipsePainter extends CustomPainter {
  final bool tile;
  final Color shadow;
  _EclipsePainter({required this.tile, required this.shadow});

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 100;
    if (tile) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Offset.zero & size, Radius.circular(24 * k)),
        Paint()..color = TenLogo.graphite,
      );
    }
    canvas.drawCircle(
        Offset(50 * k, 52 * k), 27 * k, Paint()..color = TenLogo.mint);
    canvas.drawCircle(Offset(63 * k, 42 * k), 25 * k, Paint()..color = shadow);
  }

  @override
  bool shouldRepaint(covariant _EclipsePainter old) =>
      old.tile != tile || old.shadow != shadow;
}
