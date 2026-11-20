import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

/// Непрерывное сканирование: ловим первый QR, который парсер распознаёт.
/// Разрешение камеры запрашивается при открытии экрана.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final text = b.rawValue;
      if (text == null || text.trim().isEmpty) continue;
      final r = const LinkParser().parse(text, sourceType: SourceType.qr);
      if (!r.isEmpty) {
        _done = true;
        Navigator.pop(context, text);
        return;
      }
      final msg = r.issues.isEmpty ? 'QR не распознан' : r.issues.first.message;
      if (msg != _hint) setState(() => _hint = msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Сканировать QR'),
        actions: [
          IconButton(
            tooltip: 'Фонарик',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'Нет доступа к камере. Разрешите его в настройках '
                          'приложения или используйте «QR из изображения».'
                      : 'Камера недоступна: ${error.errorCode.name}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Text(
              _hint ?? 'Наведите камеру на QR-код с ключом или ссылкой',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  shadows: [Shadow(blurRadius: 4)]),
            ),
          ),
        ],
      ),
    );
  }
}
