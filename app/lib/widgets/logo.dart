import 'package:flutter/material.dart';

/// Название приложения — в одном месте.
const appName = 'Bear VPN';

/// Фирменные цвета Bear: жёлтый и чёрный.
class BearColors {
  static const yellow = Color(0xFFFFC400);
  static const black = Color(0xFF0A0A0A);
}

/// Знак Bear: рычащий медведь на жёлтой плашке.
/// Исходник — app/branding/bear_icon.svg, картинка — assets/logo.png.
class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/logo.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: appName,
    );
  }
}
