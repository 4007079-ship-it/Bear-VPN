import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../vpn_controller.dart';

/// Карточка «Текущий трафик» / «Общий трафик».
class TrafficCard extends StatelessWidget {
  final String title;
  final String up;
  final String down;
  const TrafficCard(
      {super.key, required this.title, required this.up, required this.down});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const mono = TextStyle(
        fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]);
    Widget line(IconData icon, Color color, String v) => Row(children: [
          Icon(icon, size: 14, color: color),
          const Spacer(),
          Text(v, style: mono),
        ]);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          line(Icons.arrow_upward, cs.primary, up),
          const SizedBox(height: 2),
          line(Icons.arrow_downward, Colors.white70, down),
        ],
      ),
    );
  }
}

/// Две карточки трафика — вертикально (боковая панель) или в ряд.
class TrafficCards extends StatelessWidget {
  final VpnController vpn;
  final Axis direction;
  const TrafficCards(
      {super.key, required this.vpn, this.direction = Axis.vertical});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vpn,
      builder: (context, _) {
        final current = TrafficCard(
          title: 'Текущий трафик',
          up: '${formatBytes(vpn.uploadSpeed)}/с',
          down: '${formatBytes(vpn.downloadSpeed)}/с',
        );
        final total = TrafficCard(
          title: 'Общий трафик',
          up: formatBytes(vpn.upload),
          down: formatBytes(vpn.download),
        );
        if (direction == Axis.vertical) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [current, const SizedBox(height: 8), total],
          );
        }
        return Row(children: [
          Expanded(child: current),
          const SizedBox(width: 8),
          Expanded(child: total),
        ]);
      },
    );
  }
}

class TrafficRow extends StatelessWidget {
  final VpnController vpn;
  const TrafficRow({super.key, required this.vpn});

  @override
  Widget build(BuildContext context) =>
      TrafficCards(vpn: vpn, direction: Axis.horizontal);
}
