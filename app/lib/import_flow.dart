import 'package:flutter/material.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import 'import_sources.dart';
import 'nodes_store.dart';
import 'screens/preview_screen.dart';
import 'screens/scanner_screen.dart';
import 'widgets/node_info.dart';

/// Меню «Добавить»: буфер, ручной ввод, QR (камера/фото/изображение), файл.
class ImportFlow {
  ImportFlow._();

  static Future<void> show(BuildContext context, NodesStore store) async {
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
          await _openPreview(context, store, clip!, SourceType.uri);
        case _AddAction.manual:
          final text = await _manualInput(context);
          if (text != null && context.mounted) {
            await _openPreview(context, store, text, SourceType.uri);
          }
        case _AddAction.camera:
          var text = await Navigator.of(context).push<String>(
              MaterialPageRoute(builder: (_) => const ScannerScreen()));
          if (isPhotoFallback(text)) text = await takePhotoAndDecodeQr();
          if (text != null && context.mounted) {
            await _openPreview(context, store, text, SourceType.qr);
          }
        case _AddAction.photo:
          final text = await takePhotoAndDecodeQr();
          if (text != null && context.mounted) {
            await _openPreview(context, store, text, SourceType.qr);
          }
        case _AddAction.image:
          final text = await pickImageAndDecodeQr();
          if (text != null && context.mounted) {
            await _openPreview(context, store, text, SourceType.qr);
          }
        case _AddAction.file:
          final text = await pickConfigFile();
          if (text != null && context.mounted) {
            await _openPreview(context, store, text, SourceType.file);
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

  static Future<String?> _manualInput(BuildContext context) {
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

  static Future<void> _openPreview(BuildContext context, NodesStore store,
      String text, SourceType st) async {
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

  static void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

enum _AddAction { clipboard, manual, camera, photo, image, file }
