import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smv_vpn/nodes_store.dart';
import 'package:smv_vpn/subscription.dart';

void main() {
  const a = 'trojan://pw1@a.example.com:443?sni=a.example.com#A';
  const b = 'trojan://pw2@b.example.com:443?sni=b.example.com#B';
  const c = 'trojan://pw3@c.example.com:443?sni=c.example.com#C';

  SubscriptionFetch fetchOf(List<String> links, {String? title}) {
    final body = base64.encode(utf8.encode(links.join('\n')));
    final r = SubscriptionFetcher.parseBody(body);
    return SubscriptionFetch(nodes: r.nodes, title: title);
  }

  test('subscription-userinfo', () {
    final u = SubscriptionUsage.parse(
        'upload=1024; download=2048; total=10737418240; expire=1798761600')!;
    expect(u.used, 3072);
    expect(u.total, 10737418240);
    expect(u.expire!.year, 2027);
    expect(SubscriptionUsage.parse(''), isNull);
  });

  test('profile-title: текст и base64', () {
    expect(SubscriptionFetcher.decodeTitle('My VPN'), 'My VPN');
    expect(
        SubscriptionFetcher.decodeTitle(
            'base64:${base64.encode(utf8.encode('Медведь'))}'),
        'Медведь');
  });

  test('base64-подписка разбирается', () {
    expect(fetchOf([a, b]).nodes.length, 2);
  });

  test('обновление: id совпадающих серверов сохраняется, ручные не трогаем',
      () {
    final store = NodesStore(persist: false);
    store.addAll(SubscriptionFetcher.parseBody(c).nodes); // ручной
    final sub = store.attachSubscription(
        'https://panel.example.com/sub/token', fetchOf([a, b], title: 'Panel'));
    expect(sub.name, 'Panel');
    expect(store.nodes.length, 3);
    final idA = store.nodesOf(sub).firstWhere((n) => n.name == 'A').id;
    store.select(idA);

    store.applyRefresh(sub, fetchOf([b, a]));
    expect(store.nodesOf(sub).length, 2);
    expect(store.nodesOf(sub).any((n) => n.id == idA), isTrue);
    expect(store.selectedId, idA);

    store.applyRefresh(sub, fetchOf([b]));
    expect(store.nodesOf(sub).length, 1);
    expect(store.nodes.length, 2);
    expect(store.selectedId, isNot(idA));

    store.removeSubscription(sub);
    expect(store.nodes.single.name, 'C');
    expect(store.subscriptions, isEmpty);
  });
}
