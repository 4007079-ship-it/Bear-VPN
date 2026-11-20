/// SMV.LinkParser — офлайн-импорт узлов для SMV-VPN.
///
/// ```dart
/// const parser = LinkParser();
/// final r = parser.parse(clipboardText);
/// for (final node in r.nodes) {
///   final issues = validateNode(node);
///   // предпросмотр: карточка узла + предупреждения
/// }
/// final qrText = shareUri(node);
/// ```
library;

export 'src/link_parser.dart' show LinkParser;
export 'src/model.dart';
export 'src/result.dart'
    show InputFormat, ParseErrorCode, ParseException, ParseIssue, ParseResult;
export 'src/uri_parsers.dart'
    show parseProxyUri, supportedSchemes, knownUnsupportedSchemes;
export 'src/uri_serializer.dart' show nodeToUri, shareUri, containsSecrets;
export 'src/validator.dart';
