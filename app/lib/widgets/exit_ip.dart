import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../vpn_controller.dart';

/// Карточка «куда подключены»: адрес сервера из ключа и реальный IP выхода,
/// который видят сайты (при каскаде/переадресации они отличаются).
class ExitIpCard extends StatelessWidget {
  final VpnController vpn;
  final String? serverAddress;
  const ExitIpCard({super.key, required this.vpn, this.serverAddress});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ip = vpn.exitIp;
    final small = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);
    Widget line(String label, Widget value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            SizedBox(width: 72, child: Text(label, style: small)),
            Expanded(child: value),
          ]),
        );

    final Widget exit;
    if (vpn.exitIpLoading) {
      exit = Text('определяю…', style: small);
    } else if (ip == null) {
      exit = Text(
          vpn.mode == ConnectionMode.proxy
              ? 'настройте программу на порт прокси'
              : '—',
          style: small);
    } else if (ip.failed) {
      exit = Text('не удалось узнать', style: TextStyle(fontSize: 12, color: cs.error));
    } else {
      exit = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${ip.flag.isEmpty ? '' : '${ip.flag} '}${ip.ip}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (ip.place.isNotEmpty || ip.isp != null)
            Text(
                [if (ip.place.isNotEmpty) ip.place, if (ip.isp != null) ip.isp!]
                    .join(' · '),
                style: small,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
        ],
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Card(
        margin: const EdgeInsets.only(top: 8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (serverAddress != null)
                      line('Сервер', Text(serverAddress!,
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                    line('Ваш IP', exit),
                    if (vpn.activeServers > 1)
                      Text('Несколько серверов: IP может меняться',
                          style: small),
                  ],
                ),
              ),
              Column(children: [
                IconButton(
                  tooltip: 'Обновить',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: vpn.exitIpLoading ? null : vpn.lookupExitIp,
                ),
                if (ip != null && !ip.failed)
                  IconButton(
                    tooltip: 'Скопировать IP',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: ip.ip));
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Скопировано: ${ip.ip}')));
                    },
                  ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
