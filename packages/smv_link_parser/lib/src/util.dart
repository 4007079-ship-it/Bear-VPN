import 'dart:convert';
import 'dart:math';

import 'result.dart';

final _rnd = Random.secure();

/// UUID v4 для `ProxyNode.id`.
String generateId() {
  final b = List<int>.generate(16, (_) => _rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

final _uuidRe = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

bool isUuid(String s) => _uuidRe.hasMatch(s);

final _b64CharsRe = RegExp(r'^[A-Za-z0-9+/=_\-\s]+$');

/// Base64 в любом варианте: стандартный, URL-safe, без padding, с переносами.
/// Возвращает null, если строка не base64 или результат — не UTF-8.
String? tryDecodeBase64(String input) {
  final s = input.trim();
  if (s.isEmpty || !_b64CharsRe.hasMatch(s)) return null;
  var t = s.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
  t = t.replaceAll('=', '');
  if (t.length % 4 == 1) return null;
  t = t.padRight(t.length + (4 - t.length % 4) % 4, '=');
  try {
    return utf8.decode(base64.decode(t));
  } on FormatException {
    return null;
  }
}

/// Base64url без padding (для SIP002 userinfo).
String encodeBase64Url(String s) =>
    base64Url.encode(utf8.encode(s)).replaceAll('=', '');

/// Percent-декодирование без превращения `+` в пробел (в отличие от
/// query-декодирования форм). При битой последовательности — строка как есть.
String pctDecode(String s) {
  try {
    return Uri.decodeComponent(s);
  } on ArgumentError {
    return s;
  } on FormatException {
    return s;
  }
}

/// Разобранная ссылка вида `scheme://userinfo@host:port/path?query#fragment`.
///
/// Разбирается вручную, а не через [Uri.parse]: реальные ссылки часто
/// содержат неэкранированные пробелы и эмодзи в имени, `+` в паролях,
/// `/` в base64-userinfo и диапазоны портов, на которых стандартный
/// парсер либо падает, либо искажает данные.
class RawLink {
  final String scheme;

  /// userinfo до последнего `@`, НЕ декодированный.
  final String? userInfo;
  final String host;
  final String portText;
  final String path;
  final Map<String, String> query;
  final String? fragment;

  /// Всё между `scheme://` и `#`/`?` — нужно для legacy-форматов
  /// (ss://BASE64, vmess://BASE64).
  final String body;

  RawLink._(this.scheme, this.userInfo, this.host, this.portText, this.path,
      this.query, this.fragment, this.body);

  /// Имя из фрагмента (декодированное) или null.
  String? get name {
    final f = fragment;
    if (f == null || f.trim().isEmpty) return null;
    return pctDecode(f).trim();
  }

  String? q(String key) {
    final v = query[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Первое непустое значение из нескольких синонимов параметра.
  String? qAny(List<String> keys) {
    for (final k in keys) {
      final v = q(k);
      if (v != null) return v;
    }
    return null;
  }

  bool qBool(List<String> keys) {
    final v = qAny(keys)?.toLowerCase();
    return v == '1' || v == 'true' || v == 'yes';
  }

  int? get port => int.tryParse(portText);

  static RawLink parse(String link) {
    final sep = link.indexOf('://');
    if (sep <= 0) {
      throw ParseException(ParseErrorCode.malformed, 'Нет схемы ссылки');
    }
    final scheme = link.substring(0, sep).toLowerCase();
    var rest = link.substring(sep + 3);

    String? fragment;
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      fragment = rest.substring(hash + 1);
      rest = rest.substring(0, hash);
    }

    var queryText = '';
    final qm = rest.indexOf('?');
    if (qm >= 0) {
      queryText = rest.substring(qm + 1);
      rest = rest.substring(0, qm);
    }
    final body = rest;

    String? userInfo;
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      userInfo = rest.substring(0, at);
      rest = rest.substring(at + 1);
    }

    var path = '';
    final slash = rest.indexOf('/');
    if (slash >= 0) {
      path = rest.substring(slash);
      rest = rest.substring(0, slash);
    }

    String host;
    var portText = '';
    if (rest.startsWith('[')) {
      final close = rest.indexOf(']');
      if (close < 0) {
        throw ParseException(
            ParseErrorCode.malformed, 'Некорректный IPv6-адрес',
            kind: scheme);
      }
      host = rest.substring(1, close);
      final after = rest.substring(close + 1);
      if (after.startsWith(':')) portText = after.substring(1);
    } else {
      final colon = rest.indexOf(':');
      if (colon >= 0) {
        host = rest.substring(0, colon);
        portText = rest.substring(colon + 1);
      } else {
        host = rest;
      }
    }

    return RawLink._(scheme, userInfo, pctDecode(host).trim(), portText.trim(),
        path, parseQuery(queryText), fragment, body);
  }
}

/// Query без form-декодирования: `+` остаётся `+`.
/// Ключи приводятся к нижнему регистру.
Map<String, String> parseQuery(String q) {
  final out = <String, String>{};
  if (q.isEmpty) return out;
  for (final part in q.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final k = eq >= 0 ? part.substring(0, eq) : part;
    final v = eq >= 0 ? part.substring(eq + 1) : '';
    out.putIfAbsent(pctDecode(k).toLowerCase(), () => pctDecode(v));
  }
  return out;
}

List<String> splitCsv(String? s) => s == null
    ? const []
    : s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

/// Скорость: `100`, `100 mbps`, `50Mbps`, `1 gbps` → Мбит/с.
int? parseMbps(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  final m = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*([kmgt]?)(?:bps|b)?\s*$',
          caseSensitive: false)
      .firstMatch(v.toString());
  if (m == null) return null;
  final n = double.parse(m.group(1)!);
  switch (m.group(2)!.toLowerCase()) {
    case 'k':
      return (n / 1000).round();
    case 'g':
      return (n * 1000).round();
    case 't':
      return (n * 1000000).round();
    default:
      return n.round();
  }
}

/// Значение из JSON/YAML как строка (числа тоже).
String? str(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

int? toInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

bool toBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }
  return false;
}

Map<String, Object?> asMap(Object? v) {
  if (v is Map) {
    return v.map((k, val) => MapEntry(k.toString(), val));
  }
  return const {};
}

List<Object?> asList(Object? v) => v is List ? List<Object?>.from(v) : const [];

/// Сокращённый тип транспорта: `raw` → tcp, `splithttp` → xhttp, `http` → h2.
String normalizeTransport(String? t) {
  final s = (t ?? 'tcp').trim().toLowerCase();
  switch (s) {
    case '':
    case 'raw':
    case 'tcp':
      return 'tcp';
    case 'splithttp':
      return 'xhttp';
    case 'http':
      return 'h2';
    default:
      return s;
  }
}
