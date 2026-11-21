import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:smv_link_parser/smv_link_parser.dart';

/// Подписка: ссылка, по которой панель (3x-ui, Marzban, Remnawave…) отдаёт
/// актуальный список серверов. Ссылка содержит личный токен — хранится
/// вместе с узлами в защищённом хранилище.
class Subscription {
  final String id;
  final String url;
  String name;

  /// Как часто обновлять, в часах.
  int intervalHours;
  DateTime? updatedAt;
  String? lastError;
  SubscriptionUsage? usage;

  Subscription({
    required this.id,
    required this.url,
    required this.name,
    this.intervalHours = 12,
    this.updatedAt,
    this.lastError,
    this.usage,
  });

  String get tag => 'sub:$id';

  bool get isDue =>
      updatedAt == null ||
      DateTime.now().difference(updatedAt!) >= Duration(hours: intervalHours);

  Map<String, Object?> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'interval_hours': intervalHours,
        'updated_at': updatedAt?.toUtc().toIso8601String(),
        'last_error': lastError,
        'usage': usage?.toJson(),
      };

  factory Subscription.fromJson(Map<String, Object?> j) => Subscription(
        id: j['id'] as String,
        url: j['url'] as String,
        name: (j['name'] as String?) ?? 'Подписка',
        intervalHours: (j['interval_hours'] as int?) ?? 12,
        updatedAt: DateTime.tryParse((j['updated_at'] as String?) ?? ''),
        lastError: j['last_error'] as String?,
        usage: j['usage'] is Map<String, Object?>
            ? SubscriptionUsage.fromJson(j['usage'] as Map<String, Object?>)
            : null,
      );
}

/// Заголовок `subscription-userinfo`: трафик и срок действия.
class SubscriptionUsage {
  final int upload;
  final int download;
  final int total; // 0 — без лимита
  final DateTime? expire;

  const SubscriptionUsage(
      {this.upload = 0, this.download = 0, this.total = 0, this.expire});

  int get used => upload + download;

  static SubscriptionUsage? parse(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final m = <String, int>{};
    for (final part in header.split(';')) {
      final kv = part.split('=');
      if (kv.length != 2) continue;
      final v = int.tryParse(kv[1].trim().split('.').first);
      if (v != null) m[kv[0].trim().toLowerCase()] = v;
    }
    if (m.isEmpty) return null;
    final e = m['expire'] ?? 0;
    return SubscriptionUsage(
      upload: m['upload'] ?? 0,
      download: m['download'] ?? 0,
      total: m['total'] ?? 0,
      expire: e > 0
          ? DateTime.fromMillisecondsSinceEpoch(e * 1000, isUtc: true)
          : null,
    );
  }

  Map<String, Object?> toJson() => {
        'upload': upload,
        'download': download,
        'total': total,
        'expire': expire?.toUtc().toIso8601String(),
      };

  factory SubscriptionUsage.fromJson(Map<String, Object?> j) =>
      SubscriptionUsage(
        upload: (j['upload'] as int?) ?? 0,
        download: (j['download'] as int?) ?? 0,
        total: (j['total'] as int?) ?? 0,
        expire: DateTime.tryParse((j['expire'] as String?) ?? ''),
      );
}

/// Результат загрузки подписки.
class SubscriptionFetch {
  final List<ProxyNode> nodes;
  final List<ParseIssue> issues;
  final String? title;
  final int? intervalHours;
  final SubscriptionUsage? usage;

  const SubscriptionFetch({
    required this.nodes,
    this.issues = const [],
    this.title,
    this.intervalHours,
    this.usage,
  });
}

class SubscriptionFetcher {
  SubscriptionFetcher._();

  static const _maxBytes = 5 * 1024 * 1024;

  /// Сначала представляемся как есть; если панель отдала страницу без
  /// серверов (часть панелей так отвечает незнакомым клиентам) — пробуем
  /// ещё раз с агентом распространённого клиента.
  static const _agents = ['Bear/0.1', 'v2rayNG/1.10.0'];

  static Future<SubscriptionFetch> fetch(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
      throw const FormatException('Ссылка подписки должна начинаться с https://');
    }
    Object? lastError;
    for (final ua in _agents) {
      try {
        final r = await _get(uri, ua);
        final parsed = parseBody(r.body);
        if (parsed.nodes.isNotEmpty) {
          return SubscriptionFetch(
            nodes: parsed.nodes,
            issues: parsed.issues,
            title: decodeTitle(r.headers['profile-title']),
            intervalHours:
                int.tryParse(r.headers['profile-update-interval'] ?? ''),
            usage: SubscriptionUsage.parse(r.headers['subscription-userinfo']),
          );
        }
        lastError = const FormatException(
            'В ответе сервера не найдено ни одного сервера');
      } on HttpException catch (e) {
        lastError = e;
        if (!e.message.startsWith('HTTP 4')) break;
      } on FormatException catch (e) {
        lastError = e;
      }
    }
    if (lastError is FormatException) throw lastError;
    throw lastError ?? const FormatException('Не удалось загрузить подписку');
  }

  static ParseResult parseBody(String body) =>
      const LinkParser().parse(body, sourceType: SourceType.subscription);

  /// `profile-title` бывает обычным текстом или `base64:…`.
  static String? decodeTitle(String? raw) {
    if (raw == null) return null;
    var t = raw.trim();
    if (t.toLowerCase().startsWith('base64:')) {
      try {
        t = utf8.decode(base64.decode(base64.normalize(t.substring(7).trim())));
      } catch (_) {
        return null;
      }
    }
    return t.isEmpty ? null : t;
  }

  static Future<({String body, Map<String, String> headers})> _get(
      Uri uri, String userAgent) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = userAgent;
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 20));
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBytes) {
          throw const FormatException('Подписка слишком большая (> 5 МБ)');
        }
      }
      final headers = <String, String>{};
      res.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      return (body: utf8.decode(bytes, allowMalformed: true), headers: headers);
    } on SocketException catch (e) {
      throw HttpException('нет связи с сервером подписки (${e.osError?.message ?? e.message})',
          uri: uri);
    } on TimeoutException {
      throw HttpException('сервер подписки не ответил', uri: uri);
    } on HandshakeException {
      throw HttpException('ошибка TLS у сервера подписки', uri: uri);
    } finally {
      client.close(force: true);
    }
  }
}

/// Понятный текст ошибки загрузки.
String subscriptionError(Object e) => switch (e) {
      FormatException(:final message) => message,
      HttpException(:final message) => 'Ошибка загрузки: $message',
      StateError(:final message) when message.contains('Insecure HTTP') =>
        'Ссылка http:// без шифрования запрещена системой — нужна https://',
      _ => 'Ошибка: $e',
    };
