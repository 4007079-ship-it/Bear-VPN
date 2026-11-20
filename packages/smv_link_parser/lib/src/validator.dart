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

bool _isIp(String s) =>
    s.contains(':') || RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(s);
