import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

import 'subscription.dart';

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
  static const _subsPrefix = 'bear.subs.v1';
  static const _chunk = 1000; // символов; с запасом под UTF-16 в Windows

  final List<ProxyNode> _nodes = [];
  final List<Subscription> _subs = [];

  List<Subscription> get subscriptions => List.unmodifiable(_subs);

  /// Подписка, из которой пришёл узел (или null — добавлен вручную).
  Subscription? subscriptionOf(ProxyNode n) {
    for (final s in _subs) {
      if (n.tags.contains(s.tag)) return s;
    }
    return null;
  }

  List<ProxyNode> nodesOf(Subscription s) =>
      [for (final n in _nodes) if (n.tags.contains(s.tag)) n];
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
      final raw = await _readChunked(_countKey, _partPrefix);
      if (raw != null) {
        final list = jsonDecode(raw) as List<Object?>;
        _nodes
          ..clear()
          ..addAll(list
              .whereType<Map<String, Object?>>()
              .map(ProxyNode.fromJson));
      }
      final subsRaw =
          await _readChunked('$_subsPrefix.parts', '$_subsPrefix.part.');
      if (subsRaw != null) {
        _subs
          ..clear()
          ..addAll((jsonDecode(subsRaw) as List<Object?>)
              .whereType<Map<String, Object?>>()
              .map(Subscription.fromJson));
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

  Future<String?> _readChunked(String countKey, String prefix) async {
    final count = int.tryParse(await _storage.read(key: countKey) ?? '');
    if (count == null || count <= 0) return null;
    final b = StringBuffer();
    for (var i = 0; i < count; i++) {
      b.write(await _storage.read(key: '$prefix$i') ?? '');
    }
    return b.toString();
  }

  Future<void> _writeChunked(String countKey, String prefix, String json) async {
    final oldCount = int.tryParse(await _storage.read(key: countKey) ?? '') ?? 0;
    final parts = <String>[
      for (var i = 0; i < json.length; i += _chunk)
        json.substring(i, i + _chunk > json.length ? json.length : i + _chunk)
    ];
    for (var i = 0; i < parts.length; i++) {
      await _storage.write(key: '$prefix$i', value: parts[i]);
    }
    for (var i = parts.length; i < oldCount; i++) {
      await _storage.delete(key: '$prefix$i');
    }
    await _storage.write(key: countKey, value: '${parts.length}');
  }

  Future<void> _save() async {
    if (!persist) return;
    try {
      await _writeChunked(_countKey, _partPrefix,
          jsonEncode([for (final n in _nodes) n.toJson()]));
      await _writeChunked('$_subsPrefix.parts', '$_subsPrefix.part.',
          jsonEncode([for (final s in _subs) s.toJson()]));
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

  // ------------------------------------------------------------------
  // Подписки

  bool hasSubscriptionUrl(String url) =>
      _subs.any((s) => s.url.trim() == url.trim());

  /// Загрузить подписку и добавить её узлы. Бросает исключение при ошибке.
  Future<Subscription> addSubscription(String url) async {
    return attachSubscription(url, await SubscriptionFetcher.fetch(url));
  }

  /// Добавить уже загруженную подписку (отдельно — для тестов).
  Subscription attachSubscription(String url, SubscriptionFetch f) {
    final sub = Subscription(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      url: url.trim(),
      name: f.title ?? Uri.tryParse(url)?.host ?? 'Подписка',
      intervalHours: f.intervalHours ?? 12,
      updatedAt: DateTime.now(),
      usage: f.usage,
    );
    _subs.add(sub);
    _replaceSubscriptionNodes(sub, f.nodes);
    return sub;
  }

  /// Обновить подписку. Ошибку записывает в [Subscription.lastError], а
  /// старый список серверов в этом случае не трогает.
  Future<bool> refreshSubscription(Subscription sub) async {
    try {
      applyRefresh(sub, await SubscriptionFetcher.fetch(sub.url));
      return true;
    } catch (e) {
      sub.lastError = subscriptionError(e);
      notifyListeners();
      _queueSave();
      return false;
    }
  }

  void applyRefresh(Subscription sub, SubscriptionFetch f) {
      sub
        ..updatedAt = DateTime.now()
        ..lastError = null
        ..usage = f.usage ?? sub.usage;
      if (f.intervalHours != null && f.intervalHours! > 0) {
        sub.intervalHours = f.intervalHours!;
      }
      if (f.title != null) sub.name = f.title!;
      _replaceSubscriptionNodes(sub, f.nodes);
  }

  bool _refreshing = false;

  /// Обновить подписки, у которых подошёл срок (запуск и раз в 15 минут).
  Future<void> refreshDue() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      for (final s in List.of(_subs)) {
        if (s.isDue && _subs.contains(s)) await refreshSubscription(s);
      }
    } finally {
      _refreshing = false;
    }
  }

  void removeSubscription(Subscription sub, {bool keepNodes = false}) {
    _subs.remove(sub);
    if (keepNodes) {
      for (var i = 0; i < _nodes.length; i++) {
        final n = _nodes[i];
        if (n.tags.contains(sub.tag)) {
          _nodes[i] = n.copyWith(
              tags: [for (final t in n.tags) if (t != sub.tag) t]);
        }
      }
    } else {
      _nodes.removeWhere((n) => n.tags.contains(sub.tag));
      if (!_nodes.any((n) => n.id == selectedId)) {
        selectedId = _nodes.isEmpty ? null : _nodes.first.id;
      }
    }
    notifyListeners();
    _queueSave();
  }

  /// Заменить узлы подписки новым списком. Совпадающие серверы сохраняют
  /// свой id — выбор и активное подключение не сбиваются.
  void _replaceSubscriptionNodes(Subscription sub, List<ProxyNode> fresh) {
    final old = {
      for (final n in _nodes)
        if (n.tags.contains(sub.tag)) n.dedupKey: n
    };
    final firstIndex = _nodes.indexWhere((n) => n.tags.contains(sub.tag));
    _nodes.removeWhere((n) => n.tags.contains(sub.tag));
    final seen = <String>{};
    final next = <ProxyNode>[];
    for (final n in fresh) {
      if (!seen.add(n.dedupKey)) continue;
      final prev = old[n.dedupKey];
      final tags = [...n.tags.where((t) => !t.startsWith('sub:')), sub.tag];
      final tagged = n.copyWith(tags: tags);
      next.add(prev == null ? tagged : _withId(tagged, prev.id));
    }
    _nodes.insertAll(
        firstIndex < 0 || firstIndex > _nodes.length ? _nodes.length : firstIndex,
        next);
    if (!_nodes.any((n) => n.id == selectedId)) {
      selectedId = _nodes.isEmpty ? null : _nodes.first.id;
    }
    notifyListeners();
    _queueSave();
  }

  static ProxyNode _withId(ProxyNode n, String id) =>
      ProxyNode.fromJson({...n.toJson(), 'id': id});

  void select(String id) {
    selectedId = id;
    notifyListeners();
    _queueSave();
  }
}
