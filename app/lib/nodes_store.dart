import 'package:flutter/foundation.dart';
import 'package:smv_link_parser/smv_link_parser.dart';

/// Список узлов. В тестовой сборке хранится только в памяти: после
/// перезапуска приложения список пуст. Постоянное хранение (с секретами
/// в Keystore / DPAPI) — отдельная задача.
class NodesStore extends ChangeNotifier {
  final List<ProxyNode> _nodes = [];
  String? selectedId;

  List<ProxyNode> get nodes => List.unmodifiable(_nodes);

  Set<String> duplicatesOf(Iterable<ProxyNode> incoming) =>
      LinkParser.duplicateIds(_nodes, incoming);

  void addAll(Iterable<ProxyNode> nodes) {
    _nodes.addAll(nodes);
    selectedId ??= _nodes.isEmpty ? null : _nodes.first.id;
    notifyListeners();
  }

  void remove(String id) {
    _nodes.removeWhere((n) => n.id == id);
    if (selectedId == id) {
      selectedId = _nodes.isEmpty ? null : _nodes.first.id;
    }
    notifyListeners();
  }

  void select(String id) {
    selectedId = id;
    notifyListeners();
  }
}
