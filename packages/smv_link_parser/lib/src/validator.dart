import 'model.dart';
import 'util.dart';

enum IssueSeverity {
  /// Узел нельзя добавить / он не заработает.
  error,

  /// Узел добавить можно, но пользователя стоит предупредить.
  warning,
}

enum ValidationCode {
  missingServer,
  invalidPort,
  invalidUuid,
  missingPassword,
  unsupportedCipher,
  legacyCipher,
  unsupportedTransport,
  realityMissingSni,
  realityMissingPublicKey,
  realityMissingFingerprint,
  insecureTls,
  invalidFlow,
  vmessLegacyAlterId,
  tlsMissingSni,
  plainTextProxy,
  invalidKey,
  missingAddress,
  awgInvalidJunk,
  awgInvalidPadding,
  awgInvalidHeaders,
  awgUnknownParams,
}

class ValidationIssue {
  final ValidationCode code;
  final IssueSeverity severity;
  final String message;
  const ValidationIssue(this.code, this.severity, this.message);

  bool get isError => severity == IssueSeverity.error;

  @override
  String toString() => '${severity.name}:${code.name} $message';
}

/// Транспорты, которые поддерживает клиент.
const supportedTransports = {'tcp', 'ws', 'grpc', 'httpupgrade', 'xhttp', 'udp'};

/// AEAD и Shadowsocks-2022.
const supportedSsCiphers = {
  'aes-128-gcm',
  'aes-192-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  'xchacha20-ietf-poly1305',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305',
};

/// Устаревшие потоковые шифры: технически работают в некоторых ядрах,
/// но небезопасны.
const legacySsCiphers = {
  'aes-128-cfb',
  'aes-192-cfb',
  'aes-256-cfb',
  'aes-128-ctr',
  'aes-192-ctr',
  'aes-256-ctr',
  'chacha20-ietf',
  'xchacha20',
  'rc4-md5',
  'none',
  'plain',
};

const validFlows = {'xtls-rprx-vision', 'xtls-rprx-vision-udp443'};

/// Проверка узла перед добавлением (экран предпросмотра).
List<ValidationIssue> validateNode(ProxyNode n) {
  final out = <ValidationIssue>[];
  void err(ValidationCode c, String m) =>
      out.add(ValidationIssue(c, IssueSeverity.error, m));
  void warn(ValidationCode c, String m) =>
      out.add(ValidationIssue(c, IssueSeverity.warning, m));

  if (n.server.trim().isEmpty) {
    err(ValidationCode.missingServer, 'Не указан адрес сервера');
  }
  if (n.port < 1 || n.port > 65535) {
    err(ValidationCode.invalidPort, 'Некорректный порт: ${n.port}');
  }

  switch (n.protocol) {
    case ProxyProtocol.vless:
    case ProxyProtocol.vmess:
    case ProxyProtocol.tuic:
      final id = n.uuid ?? '';
      // Xray допускает произвольную строку вместо UUID (хешируется),
      // поэтому для vless/vmess это предупреждение, для tuic — ошибка.
      if (id.isEmpty) {
        err(ValidationCode.invalidUuid, 'Не указан UUID');
      } else if (!isUuid(id)) {
        if (n.protocol == ProxyProtocol.tuic) {
          err(ValidationCode.invalidUuid, 'UUID имеет неверный формат');
        } else {
          warn(ValidationCode.invalidUuid,
              'UUID имеет нестандартный формат — проверьте ключ');
        }
      }
      if (n.protocol == ProxyProtocol.tuic && (n.password ?? '').isEmpty) {
        err(ValidationCode.missingPassword, 'Не указан пароль TUIC');
      }
    case ProxyProtocol.trojan:
      if ((n.password ?? '').isEmpty) {
        err(ValidationCode.missingPassword, 'Не указан пароль');
      }
    case ProxyProtocol.hysteria2:
      if ((n.password ?? '').isEmpty) {
        warn(ValidationCode.missingPassword,
            'Не указан пароль (auth) — большинство серверов его требуют');
      }
    case ProxyProtocol.shadowsocks:
      final m = n.method ?? '';
      if ((n.password ?? '').isEmpty && m != 'none' && m != 'plain') {
        err(ValidationCode.missingPassword, 'Не указан пароль');
      }
      if (legacySsCiphers.contains(m)) {
        warn(ValidationCode.legacyCipher,
            'Устаревший шифр «$m» — соединение небезопасно');
      } else if (!supportedSsCiphers.contains(m)) {
        err(ValidationCode.unsupportedCipher, 'Шифр «$m» не поддерживается');
      }
    case ProxyProtocol.socks:
    case ProxyProtocol.http:
      if (!n.security.isTls) {
        warn(ValidationCode.plainTextProxy,
            'Прокси без шифрования: трафик и пароль передаются открыто');
      }
    case ProxyProtocol.wireguard:
    case ProxyProtocol.amneziawg:
      _validateWireGuard(n, err, warn);
  }

  if (!supportedTransports.contains(n.transport.type)) {
    err(ValidationCode.unsupportedTransport,
        'Транспорт «${n.transport.type}» не поддерживается');
  }

  final sec = n.security;
  if (sec.isReality) {
    if ((sec.sni ?? '').isEmpty) {
      err(ValidationCode.realityMissingSni,
          'Для Reality обязателен SNI (параметр sni)');
    }
    if ((sec.publicKey ?? '').isEmpty) {
      err(ValidationCode.realityMissingPublicKey,
          'Для Reality обязателен публичный ключ (параметр pbk)');
    }
    if ((sec.fingerprint ?? '').isEmpty) {
      warn(ValidationCode.realityMissingFingerprint,
          'Не указан fingerprint — будет использован chrome');
    }
  } else if (sec.type == 'tls' &&
      (sec.sni ?? '').isEmpty &&
      _isIp(n.server)) {
    warn(ValidationCode.tlsMissingSni,
        'TLS к IP-адресу без SNI — сертификат, скорее всего, не пройдёт проверку');
  }

  if (sec.insecure) {
    warn(ValidationCode.insecureTls,
        'Проверка сертификата отключена (insecure) — возможен перехват трафика');
  }

  final flow = n.flow;
  if (flow != null && flow.isNotEmpty) {
    if (!validFlows.contains(flow)) {
      err(ValidationCode.invalidFlow, 'Неизвестный flow: $flow');
    } else if (n.transport.type != 'tcp' || !sec.isTls) {
      err(ValidationCode.invalidFlow,
          'flow=$flow работает только с транспортом tcp и TLS/Reality');
    }
  }

  if (n.protocol == ProxyProtocol.vmess && (n.alterId ?? 0) > 0) {
    warn(ValidationCode.vmessLegacyAlterId,
        'VMess с alterId > 0 (устаревший режим) — может не работать');
  }

  return out;
}

typedef _Report = void Function(ValidationCode, String);

bool _isWgKey(String? k) {
  if (k == null) return false;
  final b = tryDecodeBase64Bytes(k);
  return b != null && b.length == 32;
}

final _hRe = RegExp(r'^(\d+)(?:-(\d+))?$');

void _validateWireGuard(ProxyNode n, _Report err, _Report warn) {
  final wg = n.wireguard;
  if (wg == null) {
    err(ValidationCode.invalidKey, 'Нет параметров WireGuard');
    return;
  }
  if (!_isWgKey(wg.privateKey)) {
    err(ValidationCode.invalidKey, 'Некорректный PrivateKey');
  }
  if (!_isWgKey(wg.peerPublicKey)) {
    err(ValidationCode.invalidKey, 'Некорректный PublicKey сервера');
  }
  if (wg.presharedKey != null && !_isWgKey(wg.presharedKey)) {
    err(ValidationCode.invalidKey, 'Некорректный PresharedKey');
  }
  if (wg.addresses.isEmpty) {
    err(ValidationCode.missingAddress, 'Не указан Address интерфейса');
  }

  final a = wg.awg;
  if (a == null) return;

  final jc = a.jc ?? 0;
  if (jc < 0 || jc > 128) {
    err(ValidationCode.awgInvalidJunk, 'Jc должен быть от 0 до 128');
  }
  if (jc > 0) {
    final jmin = a.jmin ?? 0;
    final jmax = a.jmax ?? 0;
    if (jmin < 0 || jmax >= 1280 || jmin > jmax) {
      err(ValidationCode.awgInvalidJunk,
          'Нужно 0 ≤ Jmin ≤ Jmax < 1280 (сейчас Jmin=$jmin, Jmax=$jmax)');
    }
  }

  void range(int? v, int max, String name) {
    if (v != null && (v < 0 || v > max)) {
      err(ValidationCode.awgInvalidPadding, '$name должен быть от 0 до $max');
    }
  }

  range(a.s1, 1132, 'S1');
  range(a.s2, 1188, 'S2');
  range(a.s3, 1216, 'S3');
  range(a.s4, 32, 'S4');
  if (a.s1 != null && a.s2 != null && a.s1! + 56 == a.s2) {
    err(ValidationCode.awgInvalidPadding,
        'S1 + 56 не должно быть равно S2 — пакеты станут различимы');
  }

  final ranges = <(int, int)>[];
  for (final (i, h) in a.headers.indexed) {
    if (h == null) continue;
    final m = _hRe.firstMatch(h.trim());
    final lo = m == null ? null : int.tryParse(m.group(1)!);
    final hi = m == null ? null : int.tryParse(m.group(2) ?? m.group(1)!);
    if (lo == null || hi == null || lo > hi || hi > 0xFFFFFFFF) {
      err(ValidationCode.awgInvalidHeaders, 'Некорректный H${i + 1}: $h');
      return;
    }
    ranges.add((lo, hi));
  }
  for (var i = 0; i < ranges.length; i++) {
    for (var j = i + 1; j < ranges.length; j++) {
      if (ranges[i].$1 <= ranges[j].$2 && ranges[j].$1 <= ranges[i].$2) {
        err(ValidationCode.awgInvalidHeaders,
            'Значения H1–H4 должны различаться и не пересекаться');
        return;
      }
    }
  }

  if (a.extra.isNotEmpty) {
    warn(ValidationCode.awgUnknownParams,
        'Параметры AmneziaWG ${a.extra.keys.join(', ')} требуют поддержки '
        'AWG 3.x в ядре клиента');
  }
}

bool _isIp(String s) =>
    s.contains(':') || RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(s);
