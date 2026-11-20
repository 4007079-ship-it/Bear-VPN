import 'model.dart';

/// Какой формат распознан во входной строке.
enum InputFormat {
  empty,
  uri,
  uriList,
  base64Subscription,
  singBoxJson,
  xrayJson,
  clashYaml,

  /// Ключ AmneziaVPN `vpn://…` или его JSON.
  amneziaKey,

  /// Конфиг WireGuard / AmneziaWG (.conf).
  wireguardConf,
  subscriptionUrl,
  unknown,
}

enum ParseErrorCode {
  /// Пустой ввод.
  empty,

  /// Строку не удалось отнести ни к одному формату.
  unrecognized,

  /// Формат распознан, но протокол не поддерживается (ssr://, wireguard…).
  unsupportedProtocol,

  /// Структура ссылки или документа нарушена.
  malformed,

  /// Нет обязательного поля (адрес, порт, uuid, пароль…).
  missingField,
}

/// Ошибка разбора одного элемента. Не содержит исходной строки целиком,
/// чтобы секреты не попадали в логи и отчёты об ошибках.
class ParseIssue {
  final ParseErrorCode code;

  /// Сообщение для пользователя (рус.).
  final String message;

  /// Схема или тип элемента (`vless`, `clash:ssr`…) — безопасно для логов.
  final String? kind;

  /// Порядковый номер элемента во входных данных (с 0), если их несколько.
  final int? index;

  const ParseIssue(this.code, this.message, {this.kind, this.index});

  ParseIssue withIndex(int i) =>
      ParseIssue(code, message, kind: kind, index: i);

  @override
  String toString() =>
      'ParseIssue(${code.name}${kind != null ? ', $kind' : ''}'
      '${index != null ? ', #$index' : ''}: $message)';
}

class ParseResult {
  final InputFormat format;
  final List<ProxyNode> nodes;
  final List<ParseIssue> issues;

  /// Найденные URL подписок (https://… без признаков прокси). Их загрузка —
  /// отдельное явное действие пользователя, парсер в сеть не ходит.
  final List<String> subscriptionUrls;

  const ParseResult({
    required this.format,
    this.nodes = const [],
    this.issues = const [],
    this.subscriptionUrls = const [],
  });

  bool get hasNodes => nodes.isNotEmpty;
  bool get isEmpty => nodes.isEmpty && subscriptionUrls.isEmpty;

  /// Ничего полезного не найдено, есть только ошибки.
  bool get isFailure => isEmpty && issues.isNotEmpty;
}

/// Внутреннее исключение парсеров отдельных элементов.
class ParseException implements Exception {
  final ParseIssue issue;
  ParseException(ParseErrorCode code, String message, {String? kind})
      : issue = ParseIssue(code, message, kind: kind);

  @override
  String toString() => issue.toString();
}
