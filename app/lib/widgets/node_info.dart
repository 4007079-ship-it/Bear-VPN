import 'package:flutter/material.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

String protocolLabel(ProxyProtocol p) => switch (p) {
      ProxyProtocol.vless => 'VLESS',
      ProxyProtocol.vmess => 'VMess',
      ProxyProtocol.hysteria2 => 'Hysteria2',
      ProxyProtocol.tuic => 'TUIC',
      ProxyProtocol.trojan => 'Trojan',
      ProxyProtocol.shadowsocks => 'Shadowsocks',
      ProxyProtocol.socks => 'SOCKS5',
      ProxyProtocol.http => 'HTTP',
      ProxyProtocol.wireguard => 'WireGuard',
      ProxyProtocol.amneziawg => 'AmneziaWG',
    };

/// Краткое описание без секретов: транспорт, шифрование, версия AWG.
String nodeSubtitle(ProxyNode n) {
  final parts = <String>[n.address];
  if (n.protocol.isWireGuardFamily) {
    final awg = n.wireguard?.awg;
    if (awg != null) parts.add('AWG ${awg.version}');
  } else {
    if (n.transport.type != 'tcp' && n.transport.type != 'udp') {
      parts.add(n.transport.type);
    }
    if (n.security.type != 'none') parts.add(n.security.type);
    if (n.portRange != null) parts.add('порты ${n.portRange}');
  }
  return parts.join(' · ');
}

class ProtocolChip extends StatelessWidget {
  final ProxyProtocol protocol;
  const ProtocolChip(this.protocol, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        protocolLabel(protocol),
        style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: cs.onSecondaryContainer),
      ),
    );
  }
}

class IssueLine extends StatelessWidget {
  final ValidationIssue issue;
  const IssueLine(this.issue, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = issue.isError ? cs.error : Colors.orange.shade800;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(issue.isError ? Icons.error_outline : Icons.warning_amber,
              size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
              child: Text(issue.message,
                  style: TextStyle(fontSize: 13, color: color))),
        ],
      ),
    );
  }
}
