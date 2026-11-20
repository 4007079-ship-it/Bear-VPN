import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Источники текста для импорта. Всё офлайн: ничего не уходит в сеть.

/// Камера есть и поддерживается сканером только на мобильных.
bool get cameraScanSupported => Platform.isAndroid || Platform.isIOS;

Future<String?> readClipboard() async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final t = data?.text?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// Файл с конфигом/ключами: .txt, .json, .yaml, .conf, .vpn …
Future<String?> pickConfigFile() async {
  final file = await openFile(
    acceptedTypeGroups: Platform.isAndroid
        ? const [] // на Android фильтр по расширениям ненадёжен
        : const [
            XTypeGroup(
              label: 'Конфиги и ключи',
              extensions: ['txt', 'json', 'yaml', 'yml', 'conf', 'vpn', 'list'],
            ),
          ],
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (bytes.length > 5 * 1024 * 1024) {
    throw const FormatException('Файл больше 5 МБ');
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Выбор изображения (скриншот, фото) и декодирование QR из него.
/// Возвращает null, если пользователь ничего не выбрал.
/// Бросает [FormatException], если QR не найден.
Future<String?> pickImageAndDecodeQr() async {
  final file = await openFile(
    acceptedTypeGroups: Platform.isAndroid
        ? const [
            XTypeGroup(label: 'Изображения', mimeTypes: ['image/*']),
          ]
        : const [
            XTypeGroup(
              label: 'Изображения',
              extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
            ),
          ],
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return compute(decodeQrFromImage, bytes);
}

/// Декодирование QR из байтов изображения (чистый Dart, в отдельном изоляте).
String decodeQrFromImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Не удалось открыть изображение');
  }
  // Крупные фото уменьшаем — так быстрее и надёжнее.
  var image = decoded;
  const maxSide = 1600;
  if (image.width > maxSide || image.height > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide)
        : img.copyResize(image, height: maxSide);
  }

  final pixels = image
      .convert(numChannels: 4)
      .getBytes(order: img.ChannelOrder.abgr)
      .buffer
      .asInt32List();
  final source = RGBLuminanceSource(image.width, image.height, pixels);

  for (final bitmap in [
    BinaryBitmap(HybridBinarizer(source)),
    BinaryBitmap(GlobalHistogramBinarizer(source)),
  ]) {
    try {
      final text = QRCodeReader().decode(bitmap).text;
      if (text.trim().isNotEmpty) return text;
    } catch (_) {
      // следующий вариант бинаризации
    }
  }
  throw const FormatException('QR не распознан');
}
