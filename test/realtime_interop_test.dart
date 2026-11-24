import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zapiack/zapiack.dart';

/// The client against a real gateway, over a real `dart:io` WebSocket. Runs only when RT_INTEROP names the gateway
/// (for example `RT_INTEROP=localhost:3015,localhost:3016` = gateway, then the address of the server that mints tokens).
void main() {
  final spec = Platform.environment['RT_INTEROP']?.split(',');

  Future<String> mint(String query) async {
    final c = HttpClient();
    try {
      final res = await (await c.getUrl(Uri.parse('http://${spec![1]}/?$query'))).close();
      return await res.transform(utf8.decoder).join();
    } finally {
      c.close();
    }
  }

  ZapiackRealtime client(String query) => ZapiackRealtime(
        getToken: () => mint(query),
        url: Uri.parse('ws://${spec![0]}'),
        backoffMin: const Duration(milliseconds: 50),
        backoffMax: const Duration(milliseconds: 200),
      );

  Future<void> until(String what, bool Function() cond) async {
    final end = DateTime.now().add(const Duration(seconds: 4));
    while (!cond()) {
      if (DateTime.now().isAfter(end)) fail('Timed out waiting for: $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('talks to the real gateway', () async {
    final ch = 'chat:interop-dart-${DateTime.now().microsecondsSinceEpoch}';
    final a = client('user=alice');
    final b = client('user=bob');
    final bGot = <RealtimeMessage>[];

    await a.connect();
    expect(a.connectionId, startsWith('cn_'));
    a.subscribe(ch).listen((_) {});
    await b.connect();
    final subB = b.subscribe(ch).listen(bGot.add);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final r = await a.publish(ch, {'text': 'hello', 'n': 1}, persist: true);
    expect(r.delivered, 2);
    await until('bob receives', () => bGot.length == 1);
    expect(bGot[0].from, 'alice');
    expect(bGot[0].event, 'message');

    // Resume: bob goes away, alice publishes twice, bob returns asking from the last id he saw.
    final lastSeen = bGot[0].msgId;
    await subB.cancel();
    b.disconnect();
    await a.publish(ch, {'n': 2}, persist: true);
    await a.publish(ch, {'n': 3}, persist: true);
    final b2 = client('user=bob');
    final got2 = <RealtimeMessage>[];
    await b2.connect();
    b2.subscribe(ch, resumeFrom: lastSeen).listen(got2.add);
    await until('replay', () => got2.length == 2);
    expect(got2.map((m) => (m.data as Map)['n']), [2, 3]);
    expect(got2.every((m) => m.replayed), isTrue);

    // Presence and signal.
    final events = <String>[];
    b2.presence(ch).changes.listen((e) => events.add('${e.action}:${e.member.user}'));
    a.presence(ch).enter({'name': 'Alice'});
    await until('presence', () => events.isNotEmpty);
    expect(events.first, 'enter:alice');
    final sig = <RealtimeMessage>[];
    b2.subscribe(ch).listen((m) {
      if (m.event == 'offer') sig.add(m);
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    a.signal(ch, b2.connectionId!, 'offer', {'sdp': 'v=0'});
    await until('signal', () => sig.length == 1);

    // Refusals.
    await expectLater(a.publish('admin:x', 1), throwsA(isA<RealtimeException>().having((e) => e.code, 'code', 403)));
    final off = client('off=1');
    await expectLater(off.connect(), throwsA(isA<RealtimeException>().having((e) => e.code, 'code', 403)));
    expect(off.state, RealtimeState.closed);

    a.disconnect();
    b2.disconnect();
  }, skip: spec == null ? 'set RT_INTEROP to run against a gateway' : false);
}
