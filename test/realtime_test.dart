import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zapiack/src/realtime.dart';

/// A line that tests drive: they push frames in as the server would, and read what the client sent.
class FakeSocket implements RealtimeSocket {
  FakeSocket(this.url);
  final Uri url;
  final _in = StreamController<String>();
  final List<Map<String, dynamic>> sent = [];
  bool closed = false;
  int? _code;

  @override
  Stream<String> get frames => _in.stream;
  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, dynamic>);
  @override
  void close() => closed = true;
  @override
  int? get closeCode => _code;

  /// What the server does.
  void receive(Map<String, Object?> frame) => _in.add(jsonEncode(frame));

  /// The line goes away, with a close code as the server's close frame would carry.
  void drop([int code = 1006]) {
    _code = code;
    unawaited(_in.close());
  }

  List<Map<String, dynamic>> ops(String op) => sent.where((f) => f['op'] == op).toList();
}

class Rig {
  Rig({List<String>? tokens}) : _tokens = [...(tokens ?? ['tok-1', 'tok-2', 'tok-3', 'tok-4'])];
  final sockets = <FakeSocket>[];
  final List<String> _tokens;
  int asked = 0;

  ZapiackRealtime client({Duration heartbeat = const Duration(seconds: 25), Duration ackTimeout = const Duration(seconds: 5)}) => ZapiackRealtime(
        getToken: () async {
          asked++;
          if (_tokens.isEmpty) throw StateError('server down');
          return _tokens.removeAt(0);
        },
        url: Uri.parse('wss://rt.test'),
        heartbeat: heartbeat,
        backoffMin: const Duration(milliseconds: 20),
        backoffMax: const Duration(milliseconds: 50),
        ackTimeout: ackTimeout,
        socketFactory: (url) async {
          final s = FakeSocket(url);
          sockets.add(s);
          return s;
        },
      );

  FakeSocket get last => sockets.last;

  Future<void> until(String what, bool Function() cond, {Duration timeout = const Duration(seconds: 3)}) async {
    final end = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(end)) fail('Timed out waiting for: $what');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Connects, and has the server say hello.
  Future<void> up(ZapiackRealtime rt, {String id = 'cn_1'}) async {
    final connecting = rt.connect();
    await until('a socket', () => sockets.isNotEmpty);
    last.receive({'op': 'hello', 'connId': id});
    await connecting;
  }
}

void main() {
  group('request: asking a service something over the line', () {
    test('sends an rpc frame and completes with the answer', () async {
      final rig = Rig();
      final rt = rig.client();
      await rig.up(rt);
      final answer = rt.request('media.join', {'a': 1});
      final frame = rig.last.ops('rpc').single;
      expect(frame['method'], 'media.join');
      expect(frame['data'], {'a': 1});
      rig.last.receive({'op': 'rpc.result', 'correlationId': frame['correlationId'], 'data': {'roomId': 'r1'}});
      expect(await answer, {'roomId': 'r1'});
      rt.disconnect();
    });

    test('an answer with no data is an empty map', () async {
      final rig = Rig();
      final rt = rig.client();
      await rig.up(rt);
      final answer = rt.request('media.leave');
      rig.last.receive({'op': 'rpc.result', 'correlationId': rig.last.ops('rpc').single['correlationId']});
      expect(await answer, isEmpty);
      rt.disconnect();
    });

    test('a refusal throws with the service\'s word for it', () async {
      final rig = Rig();
      final rt = rig.client();
      await rig.up(rt);
      final answer = rt.request('media.produce');
      rig.last.receive({'op': 'rpc.error', 'correlationId': rig.last.ops('rpc').single['correlationId'], 'code': 'forbidden', 'message': 'You can only listen.'});
      await expectLater(answer, throwsA(isA<RealtimeException>().having((e) => e.reason, 'reason', 'forbidden').having((e) => e.message, 'message', 'You can only listen.')));
      rt.disconnect();
    });

    test('is never queued: with no line it fails at once', () async {
      final rt = Rig().client();
      await expectLater(rt.request('media.join'), throwsA(isA<RealtimeException>().having((e) => e.reason, 'reason', 'no_route')));
    });

    test('two answers that cross are matched to the right asker', () async {
      final rig = Rig();
      final rt = rig.client();
      await rig.up(rt);
      final a = rt.request('one');
      final b = rt.request('two');
      final frames = rig.last.ops('rpc');
      rig.last.receive({'op': 'rpc.result', 'correlationId': frames[1]['correlationId'], 'data': {'n': 2}});
      rig.last.receive({'op': 'rpc.result', 'correlationId': frames[0]['correlationId'], 'data': {'n': 1}});
      expect(await a, {'n': 1});
      expect(await b, {'n': 2});
      rt.disconnect();
    });

    test('the line dropping fails what is waiting, and so does disconnecting', () async {
      final rig = Rig();
      final rt = rig.client();
      await rig.up(rt);
      final waiting = rt.request('media.join');
      final failed = expectLater(waiting, throwsA(isA<RealtimeException>().having((e) => e.reason, 'reason', 'no_route')));
      rig.last.drop();
      await failed;

      final rt2 = Rig().client();
      final rig2 = Rig();
      final c = rig2.client();
      await rig2.up(c);
      final w2 = c.request('x');
      final f2 = expectLater(w2, throwsA(isA<RealtimeException>()));
      c.disconnect();
      await f2;
      expect(rt2.state, RealtimeState.idle);
    });

    test('gives up when the server never answers', () async {
      final rig = Rig();
      final rt = rig.client(ackTimeout: const Duration(milliseconds: 50));
      await rig.up(rt);
      await expectLater(rt.request('media.join'), throwsA(isA<RealtimeException>().having((e) => e.reason, 'reason', 'timeout')));
      rt.disconnect();
    });
  });

  test('connects with the token in the address and reports state', () async {
    final rig = Rig(tokens: ['a b/c']);
    final rt = rig.client();
    final states = <RealtimeState>[];
    rt.states.listen(states.add);
    await rig.up(rt, id: 'cn_9');
    expect(rig.last.url.toString(), 'wss://rt.test/?token=a+b%2Fc');
    expect(rt.state, RealtimeState.connected);
    expect(rt.connectionId, 'cn_9');
    await Future<void>.delayed(Duration.zero);
    expect(states, [RealtimeState.connecting, RealtimeState.connected]);
    rt.disconnect();
  });

  test('subscribes when the line opens, delivers messages, and leaves when the last listener cancels', () async {
    final rig = Rig();
    final rt = rig.client();
    final got = <String>[];
    // Subscribed before connecting: sent as soon as it can be.
    final sub = rt.subscribe('chat:r1').listen((m) => got.add('${m.event}:${jsonEncode(m.data)}'));
    await rig.up(rt);
    await rig.until('subscribe', () => rig.last.ops('subscribe').any((f) => f['channel'] == 'chat:r1'));
    rig.last.receive({'op': 'message', 'msgId': '1-0', 'ts': 1, 'channel': 'chat:r1', 'event': 'message', 'data': {'hi': 1}, 'from': 'u1'});
    rig.last.receive({'op': 'message', 'msgId': '1-1', 'ts': 1, 'channel': 'other', 'event': 'message', 'data': 0, 'from': 'u1'});
    await rig.until('the message', () => got.isNotEmpty);
    expect(got, ['message:{"hi":1}']);
    await sub.cancel();
    expect(rig.last.sent.last, {'op': 'unsubscribe', 'channel': 'chat:r1'});
    rt.disconnect();
  });

  test('publish completes on ack and throws the server\'s reason on refusal', () async {
    final rig = Rig();
    final rt = rig.client();
    await rig.up(rt);

    final ok = rt.publish('c', {'a': 1}, persist: true);
    await rig.until('the publish', () => rig.last.ops('publish').isNotEmpty);
    var frame = rig.last.ops('publish').last;
    expect(frame['persist'], true);
    rig.last.receive({'op': 'ack', 'ackId': frame['ackId'], 'msgId': '9-0', 'delivered': 3});
    expect(await ok, const PublishResult(msgId: '9-0', delivered: 3));

    final refused = rt.publish('c', 1);
    final caught = expectLater(refused, throwsA(isA<RealtimeException>().having((e) => e.code, 'code', 403)));
    await rig.until('the second publish', () => rig.last.ops('publish').length == 2);
    frame = rig.last.ops('publish').last;
    rig.last.receive({'op': 'error', 'code': 403, 'message': 'Not allowed to publish to c.', 'ref': frame['ackId']});
    await caught;
    rt.disconnect();
  });

  test('publish gives up when nothing confirms', () async {
    final rig = Rig();
    final rt = rig.client(ackTimeout: const Duration(milliseconds: 100));
    await rig.up(rt);
    await expectLater(rt.publish('c', null), throwsA(isA<RealtimeException>().having((e) => e.message, 'message', contains('did not confirm'))));
    rt.disconnect();
  });

  test('reconnects with a new token and resumes from the last persisted message; a replay does not repeat what was seen', () async {
    final rig = Rig();
    final rt = rig.client();
    final got = <String>[];
    rt.subscribe('c').listen((m) => got.add('${m.data}:${m.replayed}'));
    await rig.up(rt);
    rig.last.receive({'op': 'message', 'msgId': '10-0', 'ts': 1, 'channel': 'c', 'event': 'message', 'data': 'a', 'persisted': true});
    rig.last.receive({'op': 'message', 'msgId': '11-0', 'ts': 1, 'channel': 'c', 'event': 'message', 'data': 'b', 'persisted': true});
    await rig.until('two messages', () => got.length == 2);

    rig.last.drop();
    await rig.until('a second socket', () => rig.sockets.length == 2);
    expect(rig.sockets[1].url.toString(), contains('token=tok-2'));
    rig.sockets[1].receive({'op': 'hello', 'connId': 'cn_2'});
    await rig.until('the resume', () => rig.sockets[1].ops('subscribe').any((f) => f['resumeFrom'] == '11-0'));
    // The server replays one already seen and one new.
    rig.sockets[1].receive({'op': 'message', 'msgId': '11-0', 'ts': 1, 'channel': 'c', 'event': 'message', 'data': 'b', 'persisted': true, 'replayed': true});
    rig.sockets[1].receive({'op': 'message', 'msgId': '12-0', 'ts': 1, 'channel': 'c', 'event': 'message', 'data': 'c', 'persisted': true, 'replayed': true});
    await rig.until('the new one', () => got.length == 3);
    expect(got, ['a:false', 'b:false', 'c:true']);
    rt.disconnect();
  });

  test('stops for good when the project refuses it', () async {
    final rig = Rig();
    final rt = rig.client();
    final connecting = rt.connect();
    final caught = expectLater(connecting, throwsA(isA<RealtimeException>().having((e) => e.code, 'code', 403)));
    await rig.until('a socket', () => rig.sockets.isNotEmpty);
    rig.last.drop(4403);
    await caught;
    expect(rt.state, RealtimeState.closed);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(rig.sockets.length, 1);
  });

  test('an error the server marks fatal also stops it, when the close code cannot be read', () async {
    final rig = Rig();
    final rt = rig.client();
    final connecting = rt.connect();
    final caught = expectLater(connecting, throwsA(isA<RealtimeException>()));
    await rig.until('a socket', () => rig.sockets.isNotEmpty);
    rig.last.receive({'op': 'error', 'code': 403, 'message': 'no', 'fatal': true});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    rig.last.drop();
    await caught;
    expect(rt.state, RealtimeState.closed);
  });

  test('replaces a refused token at once rather than waiting', () async {
    final rig = Rig();
    final rt = rig.client();
    await rig.up(rt);
    rig.last.drop(4401);
    await rig.until('a second socket', () => rig.sockets.length == 2, timeout: const Duration(seconds: 1));
    expect(rig.sockets[1].url.toString(), contains('tok-2'));
    rt.disconnect();
  });

  test('holds sends while reconnecting and sends them in order', () async {
    final rig = Rig();
    final rt = rig.client();
    await rig.up(rt);
    final states = <RealtimeState>[];
    rt.states.listen(states.add);
    rig.last.drop();
    // Only once the client has noticed the line is gone: a write in the instant before would go to a dead socket.
    await rig.until('the client to notice', () => states.contains(RealtimeState.reconnecting));
    rt.publishWithoutAck('c', 'one');
    rt.publishWithoutAck('c', 'two');
    await rig.until('a second socket', () => rig.sockets.length == 2);
    rig.sockets[1].receive({'op': 'hello', 'connId': 'cn_2'});
    await rig.until('both sends', () => rig.sockets[1].ops('publish').length == 2);
    expect(rig.sockets[1].ops('publish').map((f) => f['data']), ['one', 'two']);
    rt.disconnect();
  });

  test('refuses a send when too many are waiting for a connection', () async {
    final rig = Rig();
    final rt = rig.client();
    await rig.up(rt);
    final states = <RealtimeState>[];
    rt.states.listen(states.add);
    rig.last.drop();
    await rig.until('the client to notice', () => states.contains(RealtimeState.reconnecting));
    for (var i = 0; i < 100; i++) {
      rt.publishWithoutAck('c', i);
    }
    await expectLater(rt.publish('c', 'over'), throwsA(isA<RealtimeException>().having((e) => e.code, 'code', 429)));
    rt.disconnect();
  });

  test('disconnect rejects what was waiting', () async {
    final rig = Rig();
    final rt = rig.client();
    await rig.up(rt);
    final waiting = rt.publish('c', null);
    final caught = expectLater(waiting, throwsA(isA<RealtimeException>().having((e) => e.message, 'message', 'Disconnected.')));
    await rig.until('the publish', () => rig.last.ops('publish').isNotEmpty);
    rt.disconnect();
    await caught;
    expect(rt.state, RealtimeState.closed);
  });

  test('keeps presence and signals one connection', () async {
    final rig = Rig();
    final rt = rig.client();
    await rig.up(rt);
    rt.subscribe('c').listen((_) {});
    final p = rt.presence('c');
    final events = <String>[];
    p.changes.listen((e) => events.add('${e.action}:${e.member.user ?? '-'}'));
    await rig.until('subscribed', () => rig.last.ops('subscribe').isNotEmpty);
    rig.last.receive({'op': 'presence.members', 'channel': 'c', 'members': [{'connId': 'cn_a', 'user': 'ann', 'data': null, 'at': 1}]});
    rig.last.receive({'op': 'message', 'msgId': '2-0', 'ts': 2, 'channel': 'c', 'event': 'presence.enter', 'data': {'connId': 'cn_b', 'user': 'bob', 'data': 1}, 'from': 'cn_b'});
    await rig.until('bob', () => events.length == 1);
    expect(p.members.map((m) => m.user), ['ann', 'bob']);
    rig.last.receive({'op': 'message', 'msgId': '3-0', 'ts': 3, 'channel': 'c', 'event': 'presence.leave', 'data': {'connId': 'cn_a', 'user': 'ann', 'data': null}, 'from': 'cn_a'});
    await rig.until('ann leaves', () => events.length == 2);
    expect(p.members.map((m) => m.user), ['bob']);
    expect(events, ['enter:bob', 'leave:ann']);

    rt.signal('c', 'cn_x', 'offer', {'sdp': 'v=0'});
    expect(rig.last.ops('signal').last['to'], 'cn_x');
    rt.disconnect();
  });

  test('gives up on a silent line and pings on a beat', () async {
    final rig = Rig();
    final rt = rig.client(heartbeat: const Duration(milliseconds: 50));
    await rig.up(rt);
    // Nothing is heard for more than two beats: the line is closed and a new one opened.
    await rig.until('a second socket', () => rig.sockets.length == 2);
    expect(rig.sockets[0].closed, isTrue);
    expect(rig.sockets[0].ops('ping'), isNotEmpty);
    rt.disconnect();
  });

  test('reports a token it could not get, and keeps trying', () async {
    final rig = Rig(tokens: []);
    final rt = rig.client();
    final errors = <String>[];
    rt.errors.listen((e) => errors.add(e.message));
    unawaited(rt.connect().then((_) {}, onError: (_) {}));
    await rig.until('the report', () => errors.isNotEmpty);
    expect(errors.first, contains('Could not get a token'));
    await rig.until('another try', () => rig.asked >= 2);
    rt.disconnect();
  });

  test('message ids are ordered by time then sequence', () {
    expect(isAfter('11-0', '10-5'), isTrue);
    expect(isAfter('10-2', '10-1'), isTrue);
    expect(isAfter('10-1', '10-1'), isFalse);
    expect(isAfter('9-9', '10-0'), isFalse);
  });
}
