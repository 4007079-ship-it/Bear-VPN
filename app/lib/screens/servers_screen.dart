import 'package:flutter/material.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import '../import_sources.dart';
import '../nodes_store.dart';
import '../vpn_controller.dart';
import '../widgets/node_info.dart';
import 'node_screen.dart';
import 'preview_screen.dart';
import 'scanner_screen.dart';

class ServersScreen extends StatelessWidget {
  final NodesStore store;
  final VpnController vpn;
  const ServersScreen({super.key, required this.store, required this.vpn});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, vpn]),
      builder: (context, _) {
        final nodes = store.nodes;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Servers'),
            actions: [
              IconButton(
                tooltip: 'О тестовой сборке',
                icon: const Icon(Icons.info_outline),
                onPressed: () => _about(context),
              ),
            ],
          ),
          body: nodes.isEmpty
              ? const _Empty()
              : Column(children: [
                  ConnectPanel(store: store, vpn: vpn),
                  const Divider(height: 1),
                  Expanded(child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: nodes.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final n = nodes[i];
                    final hasErrors =
                        validateNode(n).any((issue) => issue.isError);
                    return ListTile(
                      leading: IconButton(
                        tooltip: 'Выбрать',
                        icon: Icon(store.selectedId == n.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked),
                        onPressed: () => store.select(n.id),
                      ),
                      title: Text(n.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(children: [
                          ProtocolChip(n.protocol),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(nodeSubtitle(n),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ]),
                      ),
                      trailing: hasErrors
                          ? Icon(Icons.error_outline,
                              color: Theme.of(context).colorScheme.error)
                          : const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => NodeScreen(store: store, node: n))),
                    );
                  },
                )),
                ]),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _showAddMenu(context),
            icon: const Icon(Icons.add),
            label: const Text('Добавить'),
          ),
        );
      },
    );
  }

  void _about(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Тестовая сборка'),
        content: const Text(
            'Тестовая сборка: импорт узлов и подключение через ядро Xray '
            '(VLESS/Reality, VMess, Trojan, Shadowsocks, Hysteria2, SOCKS).\n\n'
            'Android — режим VPN. Windows — режим системного прокси '
            '(без прав администратора; работают браузеры и программы, '
            'которые используют системный прокси).\n\n'
            'AmneziaWG, WireGuard и TUIC пока только импортируются — '
            'подключение к ним появится позже.\n\n'
            'Список узлов хранится в памяти и очищается при перезапуске.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _showAddMenu(BuildContext context) async {
    final clip = await readClipboard();
    final clipResult = clip == null ? null : const LinkParser().parse(clip);
    final clipUseful = clipResult != null && !clipResult.isEmpty;
    if (!context.mounted) return;

    final action = await showModalBottomSheet<_AddAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Из буфера обмена'),
              subtitle: Text(clipUseful
                  ? 'Найдено: ${_describe(clipResult!)}'
                  : 'В буфере нет ссылки или ключа'),
              enabled: clipUseful,
              onTap: () => Navigator.pop(context, _AddAction.clipboard),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Вставить вручную'),
              onTap: () => Navigator.pop(context, _AddAction.manual),
            ),
            if (cameraScanSupported) ...[
              ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('Сканировать QR'),
                onTap: () => Navigator.pop(context, _AddAction.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Сфотографировать QR'),
                subtitle: const Text('Если сканер не запускается'),
                onTap: () => Navigator.pop(context, _AddAction.photo),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('QR из изображения'),
              subtitle: const Text('Скриншот или фото'),
              onTap: () => Navigator.pop(context, _AddAction.image),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Из файла'),
              subtitle: const Text('.txt .json .yaml .conf .vpn'),
              onTap: () => Navigator.pop(context, _AddAction.file),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    try {
      switch (action) {
        case _AddAction.clipboard:
          await _openPreview(context, clip!, SourceType.uri);
        case _AddAction.manual:
          final text = await _manualInput(context);
          if (text != null && context.mounted) {
            await _openPreview(context, text, SourceType.uri);
          }
        case _AddAction.camera:
          var text = await Navigator.of(context).push<String>(
              MaterialPageRoute(builder: (_) => const ScannerScreen()));
          if (isPhotoFallback(text)) text = await takePhotoAndDecodeQr();
          if (text != null && context.mounted) {
            await _openPreview(context, text, SourceType.qr);
          }
        case _AddAction.photo:
          final text = await takePhotoAndDecodeQr();
          if (text != null && context.mounted) {
            await _openPreview(context, text, SourceType.qr);
          }
        case _AddAction.image:
          final text = await pickImageAndDecodeQr();
          if (text != null && context.mounted) {
            await _openPreview(context, text, SourceType.qr);
          }
        case _AddAction.file:
          final text = await pickConfigFile();
          if (text != null && context.mounted) {
            await _openPreview(context, text, SourceType.file);
          }
      }
    } on FormatException catch (e) {
      if (context.mounted) _snack(context, e.message);
    } catch (e) {
      if (context.mounted) _snack(context, 'Ошибка: $e');
    }
  }

  static String _describe(ParseResult r) {
    if (r.nodes.isNotEmpty) {
      final n = r.nodes.length;
      return n == 1
          ? '${protocolLabel(r.nodes.first.protocol)} · ${r.nodes.first.address}'
          : '$n узлов';
    }
    return 'ссылка подписки';
  }

  Future<String?> _manualInput(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Вставьте ссылку или ключ'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'vless://…, hysteria2://…, vpn://…, base64, JSON, '
                  'YAML или .conf',
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Разобрать')),
        ],
      ),
    );
  }

  Future<void> _openPreview(
      BuildContext context, String text, SourceType st) async {
    final result = const LinkParser().parse(text, sourceType: st);
    if (result.nodes.isEmpty && result.subscriptionUrls.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Это ссылка подписки'),
          content: Text(
              '${result.subscriptionUrls.first}\n\nЗагрузка подписок по URL '
              'появится в следующей сборке. Сейчас можно вставить содержимое '
              'подписки (base64 или список ссылок).'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    if (result.nodes.isEmpty) {
      _snack(
          context,
          result.issues.isEmpty
              ? 'Ничего не найдено'
              : result.issues.first.message);
      return;
    }
    final added = await Navigator.of(context).push<int>(MaterialPageRoute(
        builder: (_) => PreviewScreen(store: store, result: result)));
    if (added != null && added > 0 && context.mounted) {
      _snack(context, added == 1 ? 'Узел добавлен' : 'Добавлено узлов: $added');
    }
  }

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

enum _AddAction { clipboard, manual, camera, photo, image, file }

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            const Text('Узлов пока нет', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            const Text(
              'Нажмите «Добавить», чтобы вставить ссылку, ключ vpn://, '
              'отсканировать QR или открыть файл.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class ConnectPanel extends StatelessWidget {
  final NodesStore store;
  final VpnController vpn;
  const ConnectPanel({super.key, required this.store, required this.vpn});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selected = store.nodes
        .where((n) => n.id == store.selectedId)
        .cast<ProxyNode?>()
        .firstWhere((_) => true, orElse: () => null);
    final active = vpn.state == VpnState.connected;
    final busy = vpn.state == VpnState.connecting ||
        vpn.state == VpnState.disconnecting;
    final unsupported =
        selected == null ? null : VpnController.unsupportedReason(selected);

    final (String title, Color color) = switch (vpn.state) {
      VpnState.connected => ('Подключено', Colors.green),
      VpnState.connecting => ('Подключение…', Colors.orange),
      VpnState.disconnecting => ('Отключение…', Colors.orange),
      VpnState.disconnected => ('Не подключено', cs.outline),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.circle, size: 12, color: color),
            const SizedBox(width: 8),
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (VpnController.proxyOnlyMode)
              const Tooltip(
                message: 'Windows: режим системного прокси',
                child: Chip(label: Text('прокси')),
              ),
          ]),
          const SizedBox(height: 4),
          Text(
            selected == null ? 'Выберите узел в списке' : selected.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          if (active) ...[
            const SizedBox(height: 6),
            Text(
              '${formatDuration(vpn.duration)}   '
              '↑ ${formatBytes(vpn.uploadSpeed)}/с  ↓ ${formatBytes(vpn.downloadSpeed)}/с   '
              'всего ${formatBytes(vpn.upload + vpn.download)}'
              '${vpn.delayMs == null ? '' : vpn.delayMs! < 0 ? '   задержка: ошибка' : '   задержка: ${vpn.delayMs} мс'}',
              style: const TextStyle(fontSize: 13),
            ),
          ],
          if (unsupported != null && !active) ...[
            const SizedBox(height: 6),
            Text(unsupported, style: TextStyle(color: cs.error, fontSize: 13)),
          ],
          if (vpn.error != null) ...[
            const SizedBox(height: 6),
            SelectableText(vpn.error!,
                style: TextStyle(color: cs.error, fontSize: 13)),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: active
                    ? FilledButton.styleFrom(backgroundColor: cs.error)
                    : null,
                onPressed: busy || selected == null || (unsupported != null && !active)
                    ? null
                    : () => active ? vpn.disconnect() : vpn.connect(selected),
                icon: Icon(active ? Icons.power_settings_new : Icons.play_arrow),
                label: Text(active ? 'Отключить' : 'Подключить'),
              ),
            ),
            if (active) ...[
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: vpn.measureDelay,
                child: const Text('Пинг'),
              ),
            ],
          ]),
        ],
      ),
    );
  }
}
