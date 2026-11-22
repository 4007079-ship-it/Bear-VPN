import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/logo.dart';

/// Версия подставляется при сборке: --dart-define=APP_VERSION=x.y.z
const appVersion = String.fromEnvironment('APP_VERSION');

/// «О программе»: автор и поддерживаемые протоколы.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _connect = [
    ('VLESS', 'Reality, XHTTP, WebSocket, gRPC, TCP + TLS'),
    ('VMess', 'WebSocket, gRPC, TCP, TLS'),
    ('Trojan', 'TLS'),
    ('Shadowsocks', 'в том числе Shadowsocks 2022'),
    ('Hysteria2', 'в том числе обфускация salamander'),
    ('SOCKS5', ''),
  ];

  static const _importOnly = [
    ('AmneziaWG', 'ключи vpn:// и файлы .conf'),
    ('WireGuard', 'ссылки и файлы .conf'),
    ('TUIC', ''),
    ('HTTP-прокси', ''),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = TextStyle(color: cs.onSurfaceVariant, fontSize: 13);

    Widget header(String t) => Padding(
          padding: const EdgeInsets.only(top: 28, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Divider(height: 1, color: cs.outlineVariant),
            ],
          ),
        );

    Widget link(String text, String copy) => InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: copy));
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Скопировано: $copy')));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(text,
                style: TextStyle(
                    color: cs.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: cs.primary)),
          ),
        );

    Widget protocol((String, String) p, bool ok) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(ok ? Icons.check_circle : Icons.download_outlined,
                  size: 18, color: ok ? cs.primary : cs.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                      text: p.$1,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (p.$2.isNotEmpty)
                    TextSpan(text: ' — ${p.$2}', style: muted),
                ])),
              ),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('О программе')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        children: [
          Row(children: [
            const AppLogo(size: 56),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(appName,
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                if (appVersion.isNotEmpty)
                  Text('Версия $appVersion', style: muted),
              ],
            ),
          ]),
          header('Автор'),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipOval(
                child: Image.asset('assets/author.png',
                    width: 96, height: 96, semanticLabel: 'SMV'),
              ),
              const SizedBox(width: 20),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('SMV', style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 2),
                  link('4007079@gmail.com', '4007079@gmail.com'),
                  link('github.com/4007079-ship-it',
                      'https://github.com/4007079-ship-it'),
                ],
              ),
            ],
          ),
          header('Протоколы'),
          Text('Подключение', style: muted),
          const SizedBox(height: 4),
          for (final p in _connect) protocol(p, true),
          const SizedBox(height: 14),
          Text('Пока только добавление (подключение появится позже)',
              style: muted),
          const SizedBox(height: 4),
          for (final p in _importOnly) protocol(p, false),
          const SizedBox(height: 14),
          Text(
            'Форматы: ссылки, ключи AmneziaVPN vpn://, подписки, '
            'sing-box, Clash, Xray JSON, QR-коды.',
            style: muted,
          ),
        ],
      ),
    );
  }
}
