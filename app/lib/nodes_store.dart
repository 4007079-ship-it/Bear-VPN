import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

/// Список серверов. Хранится в защищённом хранилище ОС, потому что в узлах
/// лежат ключи доступа: Android — Keystore (EncryptedSharedPreferences),
/// Windows — Диспетчер учётных данных (DPAPI).
///
/// У Windows значение ограничено ~2,5 КБ, поэтому JSON режется на части.
class NodesStore extends ChangeNotifier {
  NodesStore({FlutterSecureStorage? storage, this.persist = true})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  /// false — только память (тесты).
  final bool persist;

  static const _countKey = 'bear.nodes.v1.parts';
  static const _partPrefix = 'bear.nodes.v1.part.';
  static const _selectedKey = 'bear.nodes.v1.selected';
  static const _chunk = 1000; // символов; с запасом под UTF-16 в Windows

  final List<ProxyNode> _nodes = [];
  String? selectedId;
  bool loaded = false;
  String? loadError;

  List<ProxyNode> get nodes => List.unmodifiable(_nodes);

  Set<String> duplicatesOf(Iterable<ProxyNode> incoming) =>
      LinkParser.duplicateIds(_nodes, incoming);

  Future<void> load() async {
    if (!persist) {
      loaded = true;
      return;
    }
    try {
      final count = int.tryParse(await _storage.read(key: _countKey) ?? '');
      if (count != null && count > 0) {
        final b = StringBuffer();
        for (var i = 0; i < count; i++) {
          b.write(await _storage.read(key: '$_partPrefix$i') ?? '');
        }
        final list = jsonDecode(b.toString()) as List<Object?>;
        _nodes
          ..clear()
          ..addAll(list
              .whereType<Map<String, Object?>>()
              .map(ProxyNode.fromJson));
      }
      final sel = await _storage.read(key: _selectedKey);
      selectedId = _nodes.any((n) => n.id == sel)
          ? sel
          : (_nodes.isEmpty ? null : _nodes.first.id);
    } catch (e) {
      loadError = 'Не удалось прочитать сохранённые серверы: $e';
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _pending = Future<void>.value();

  /// Сохранения идут строго по очереди, чтобы части не перемешались.
  void _queueSave() {
    _pending = _pending.then((_) => _save());
  }

  Future<void> _save() async {
    if (!persist) return;
    try {
      final json = jsonEncode([for (final n in _nodes) n.toJson()]);
      final oldCount =
          int.tryParse(await _storage.read(key: _countKey) ?? '') ?? 0;
      final parts = <String>[
        for (var i = 0; i < json.length; i += _chunk)
          json.substring(i, i + _chunk > json.length ? json.length : i + _chunk)
      ];
      for (var i = 0; i < parts.length; i++) {
        await _storage.write(key: '$_partPrefix$i', value: parts[i]);
      }
      for (var i = parts.length; i < oldCount; i++) {
        await _storage.delete(key: '$_partPrefix$i');
      }
      await _storage.write(key: _countKey, value: '${parts.length}');
      if (selectedId == null) {
        await _storage.delete(key: _selectedKey);
      } else {
        await _storage.write(key: _selectedKey, value: selectedId);
      }
    } catch (e) {
      debugPrint('NodesStore save failed: $e');
    }
  }

  void addAll(Iterable<ProxyNode> nodes) {
    _nodes.addAll(nodes);
    selectedId ??= _nodes.isEmpty ? null : _nodes.first.id;
    notifyListeners();
    _queueSave();
  }

  void remove(String id) {
    _nodes.removeWhere((n) => n.id == id);
    if (selectedId == id) {
      selectedId = _nodes.isEmpty ? null : _nodes.first.id;
    }
    notifyListeners();
    _queueSave();
  }

  void select(String id) {
    selectedId = id;
    notifyListeners();
    _queueSave();
  }
}
