import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'amnezia.dart';
import 'config_formats.dart';
import 'model.dart';
import 'result.dart';
import 'uri_parsers.dart';
import 'util.dart';
import 'wireguard.dart';

/// SMV.LinkParser — единая точка входа для поля «Вставьте ссылку или ключ»,
/// буфера обмена, QR-кодов и файлов.
///
/// Работает полностью офлайн: никаких сетевых запросов. URL подписок
/// возвращаются в [ParseResult.subscriptionUrls], загружает их вызывающий код.
class LinkParser {
  /// Ограничение на размер входа, чтобы случайная вставка мегабайтного
  /// текста не подвесила UI.
  static const maxInputLength = 5 * 1024 * 1024;

  const LinkParser();

  ParseResult parse(String input,
      {SourceType sourceType = SourceType.uri, DateTime? now}) {
    final ts = now ?? DateTime.now();
    if (input.length > maxInputLength) {
      return const ParseResult(format: InputFormat.unknown, issues: [
        ParseIssue(ParseErrorCode.malformed, 'Слишком большой объём данных')
      ]);
    }
    final r = _parse(input, sourceType, ts, depth: 0);
    return _dedupe(r);
  }

  ParseResult _parse(String input, SourceType st, DateTime now,
      {required int depth}) {
    final text = input.replaceFirst('﻿', '').trim();
    if (text.isEmpty) {
      return const ParseResult(format: InputFormat.empty, issues: [
        ParseIssue(ParseErrorCode.empty, 'Вставьте ссылку или ключ')
      ]);
    }

    // До JSON: .conf тоже начинается с '['.
    if (looksLikeWgConf(text)) {
      return _parseWgConf(text, st, now);
    }

    if (text.startsWith('{') || text.startsWith('[')) {
      return _parseJson(text, st, now);
    }

    if (_clashProxiesRe.hasMatch(text)) {
      return _parseClash(text, st, now);
    }

    if (text.contains('://')) {
      return _parseLinks(text, st, now);
    }

    // Base64-подписка (или base64 от одной ссылки / JSON / YAML).
    if (depth < 2) {
      final decoded = tryDecodeBase64(text);
      if (decoded != null && _looksLikeText(decoded)) {
        final inner = _parse(decoded, st, now, depth: depth + 1);
        if (inner.format != InputFormat.unknown) {
          final fmt = (inner.format == InputFormat.uri ||
                  inner.format == InputFormat.uriList)
              ? InputFormat.base64Subscription
              : inner.format;
          return ParseResult(
            format: fmt,
            nodes: inner.nodes,
            issues: inner.issues,
            subscriptionUrls: inner.subscriptionUrls,
          );
        }
      }
    }

    return const ParseResult(format: InputFormat.unknown, issues: [
      ParseIssue(ParseErrorCode.unrecognized,
          'Не удалось распознать: ожидается ссылка (vless://, hysteria2://, '
          'vpn://…), base64-подписка, JSON sing-box/Xray, YAML Clash '
          'или конфиг AmneziaWG/WireGuard')
    ]);
  }

  // -------------------------------------------------------------------------
  // Ссылки

  static final _clashProxiesRe = RegExp(r'^proxies\s*:', multiLine: true);

  /// Разделители между ссылками: переводы строк, а также пробелы и запятые,
  /// но только перед началом следующей ссылки — чтобы не резать
  /// неэкранированные пробелы в имени и `alpn=h2,http/1.1`.
  static final _lineSplitRe = RegExp(r'[\r\n]+');
  static final _inlineSplitRe =
      RegExp(r'[\s,]+(?=[A-Za-z][A-Za-z0-9+.\-]*://)');

  static List<String> splitLinks(String text) {
    final out = <String>[];
    for (final line in text.split(_lineSplitRe)) {
      final l = line.trim();
      if (l.isEmpty || l.startsWith('#') || l.startsWith('//')) continue;
      for (final t in l.split(_inlineSplitRe)) {
        final s = t.trim();
        if (s.isNotEmpty) out.add(s);
      }
    }
    return out;
  }

  ParseResult _parseLinks(String text, SourceType st, DateTime now) {
    final tokens = splitLinks(text);
    final nodes = <ProxyNode>[];
    final issues = <ParseIssue>[];
    final subs = <String>[];

    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (!t.contains('://')) {
        issues.add(const ParseIssue(
                ParseErrorCode.unrecognized, 'Строка не похожа на ссылку')
            .withIndex(i));
        continue;
      }
      if (isSubscriptionUrl(t)) {
        subs.add(t);
        continue;
      }
      if (t.toLowerCase().startsWith('vpn://')) {
        final json = decodeAmneziaKey(t);
        if (json == null) {
          issues.add(const ParseIssue(ParseErrorCode.malformed,
                  'Повреждённый ключ AmneziaVPN (vpn://)',
                  kind: 'amnezia')
              .withIndex(i));
          continue;
        }
        final r = extractAmnezia(json, raw: t, sourceType: st, now: now);
        nodes.addAll(r.nodes);
        issues.addAll(r.issues.map((e) => e.index == null ? e.withIndex(i) : e));
        continue;
      }
      try {
        nodes.add(parseProxyUri(t, sourceType: st, now: now));
      } on ParseException catch (e) {
        issues.add(e.issue.withIndex(i));
      }
    }

    final InputFormat fmt;
    if (nodes.isEmpty && subs.isNotEmpty) {
      fmt = InputFormat.subscriptionUrl;
    } else if (tokens.length == 1 &&
        tokens.single.toLowerCase().startsWith('vpn://')) {
      fmt = InputFormat.amneziaKey;
    } else {
      fmt = tokens.length == 1 ? InputFormat.uri : InputFormat.uriList;
    }
    return ParseResult(
        format: fmt, nodes: nodes, issues: issues, subscriptionUrls: subs);
  }

  /// `https://…` — всегда URL подписки. `http://…` — подписка, если есть
  /// путь или query и нет логина/пароля; иначе это HTTP-прокси.
  static bool isSubscriptionUrl(String link) {
    final lower = link.toLowerCase();
    if (lower.startsWith('https://')) return true;
    if (!lower.startsWith('http://')) return false;
    try {
      final l = RawLink.parse(link);
      if (l.userInfo != null) return false;
      final hasPath = l.path.isNotEmpty && l.path != '/';
      return hasPath || l.query.isNotEmpty;
    } on ParseException {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // JSON: sing-box / Xray

  ParseResult _parseJson(String text, SourceType st, DateTime now) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return const ParseResult(format: InputFormat.unknown, issues: [
        ParseIssue(ParseErrorCode.malformed, 'Повреждённый JSON')
      ]);
    }

    final singBox = <Object?>[];
    final xray = <Object?>[];
    var clash = <Object?>[];
    final amnezia = <Map<String, Object?>>[];

    void collectOutbound(Object? o) {
      final m = asMap(o);
      if (m.isEmpty) return;
      if (looksLikeXrayOutbound(m)) {
        xray.add(m);
      } else if (looksLikeSingBoxOutbound(m)) {
        singBox.add(m);
      }
    }

    void collectConfig(Object? c) {
      final m = asMap(c);
      if (looksLikeAmneziaJson(m)) {
        amnezia.add(m);
      } else if (m.containsKey('outbounds')) {
        asList(m['outbounds']).forEach(collectOutbound);
      } else if (m.containsKey('proxies')) {
        clash = [...clash, ...asList(m['proxies'])];
      } else {
        collectOutbound(m);
      }
    }

    if (json is List) {
      json.forEach(collectConfig);
    } else {
      collectConfig(json);
    }

    if (amnezia.isNotEmpty && singBox.isEmpty && xray.isEmpty && clash.isEmpty) {
      final nodes = <ProxyNode>[];
      final issues = <ParseIssue>[];
      for (final a in amnezia) {
        final r = extractAmnezia(a, raw: text, sourceType: st, now: now);
        nodes.addAll(r.nodes);
        issues.addAll(r.issues);
      }
      return ParseResult(
          format: InputFormat.amneziaKey, nodes: nodes, issues: issues);
    }

    if (singBox.isEmpty && xray.isEmpty && clash.isEmpty) {
      return const ParseResult(format: InputFormat.unknown, issues: [
        ParseIssue(ParseErrorCode.unrecognized,
            'В JSON не найдено ни одного узла (ожидается outbounds sing-box или Xray)')
      ]);
    }

    final nodes = <ProxyNode>[];
    final issues = <ParseIssue>[];
    if (singBox.isNotEmpty) {
      final r = extractSingBox(singBox, sourceType: st, now: now);
      nodes.addAll(r.nodes);
      issues.addAll(r.issues);
    }
    if (xray.isNotEmpty) {
      final r = extractXray(xray, sourceType: st, now: now);
      nodes.addAll(r.nodes);
      issues.addAll(r.issues);
    }
    if (clash.isNotEmpty) {
      final r = extractClash(clash, sourceType: st, now: now);
      nodes.addAll(r.nodes);
      issues.addAll(r.issues);
    }

    final fmt = xray.length > singBox.length
        ? InputFormat.xrayJson
        : (singBox.isNotEmpty ? InputFormat.singBoxJson : InputFormat.clashYaml);
    if (nodes.isEmpty && issues.isEmpty) {
      issues.add(const ParseIssue(ParseErrorCode.unrecognized,
          'В конфиге нет прокси-узлов (только служебные outbounds)'));
    }
    return ParseResult(format: fmt, nodes: nodes, issues: issues);
  }

  // -------------------------------------------------------------------------
  // WireGuard / AmneziaWG .conf

  ParseResult _parseWgConf(String text, SourceType st, DateTime now) {
    try {
      final node = parseWgConf(text,
          source: NodeSource(type: st, raw: text, importedAt: now.toUtc()));
      return ParseResult(format: InputFormat.wireguardConf, nodes: [node]);
    } on ParseException catch (e) {
      return ParseResult(format: InputFormat.wireguardConf, issues: [e.issue]);
    }
  }

  // -------------------------------------------------------------------------
  // YAML: Clash / Mihomo

  ParseResult _parseClash(String text, SourceType st, DateTime now) {
    Object? doc;
    try {
      doc = _yamlToDart(loadYaml(text));
    } on YamlException {
      return const ParseResult(format: InputFormat.clashYaml, issues: [
        ParseIssue(ParseErrorCode.malformed, 'Повреждённый YAML')
      ]);
    }
    final proxies = asList(asMap(doc)['proxies']);
    if (proxies.isEmpty) {
      return const ParseResult(format: InputFormat.clashYaml, issues: [
        ParseIssue(ParseErrorCode.unrecognized, 'Секция proxies пуста')
      ]);
    }
    final r = extractClash(proxies, sourceType: st, now: now);
    return ParseResult(
        format: InputFormat.clashYaml, nodes: r.nodes, issues: r.issues);
  }

  static Object? _yamlToDart(Object? v) {
    if (v is YamlMap) {
      return {
        for (final e in v.entries) e.key.toString(): _yamlToDart(e.value)
      };
    }
    if (v is YamlList) return [for (final e in v) _yamlToDart(e)];
    return v;
  }

  // -------------------------------------------------------------------------

  static bool _looksLikeText(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    // Отсекаем «случайный» base64, который декодируется в мусор.
    final control = t.runes
        .where((r) => r < 0x20 && r != 0x0a && r != 0x0d && r != 0x09)
        .length;
    return control == 0;
  }

  /// Убирает дубликаты внутри одного импорта (по протоколу, адресу и
  /// учётным данным), оставляя первый.
  static ParseResult _dedupe(ParseResult r) {
    if (r.nodes.length < 2) return r;
    final seen = <String>{};
    final unique = [
      for (final n in r.nodes)
        if (seen.add(n.dedupKey)) n
    ];
    if (unique.length == r.nodes.length) return r;
    return ParseResult(
      format: r.format,
      nodes: unique,
      issues: r.issues,
      subscriptionUrls: r.subscriptionUrls,
    );
  }

  /// Узлы из [incoming], которые уже есть в [existing] (для предупреждения
  /// «уже добавлен» в предпросмотре и для обновления подписки).
  static Set<String> duplicateIds(
      Iterable<ProxyNode> existing, Iterable<ProxyNode> incoming) {
    final keys = {for (final n in existing) n.dedupKey};
    return {
      for (final n in incoming)
        if (keys.contains(n.dedupKey)) n.id
    };
  }
}
