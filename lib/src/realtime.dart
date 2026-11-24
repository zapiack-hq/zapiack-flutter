import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Zapiack Realtime: live messages over one WebSocket.
///
/// Your server mints a short-lived token with its API key (`POST /v1/realtime/tokens`) and hands it to the app, so the API key never
/// reaches the device. The client asks for a token every time it connects, so one that expires is simply replaced.
///
/// It reconnects by itself with a growing, jittered pause, re-joins every channel and asks for what it missed since the last persisted
/// message it saw, so a lost signal costs no messages. It is pure Dart: no native setup.

enum RealtimeState { idle, connecting, connected, reconnecting, closed }

@immutable
class RealtimeMessage {
  const RealtimeMessage({required this.msgId, required this.ts, required this.channel, required this.event, required this.data, this.from, this.replayed = false});

  final String msgId;
  final num ts;
  final String channel;
  final String event;

  /// The JSON the sender gave: a Map, List, String, number, bool or null.
  final Object? data;

  /// The user id (or connection id) of the sender.
  final String? from;

  /// True when it was sent while this client was away and is being replayed.
  final bool replayed;
}

@immutable
class PresenceMember {
  const PresenceMember({required this.connId, this.user, this.data});
  final String connId;
  final String? user;
  final Object? data;
}

@immutable
class PublishResult {
  const PublishResult({required this.msgId, required this.delivered});
  final String msgId;

  /// How many connections were subscribed when it was sent.
  final int delivered;

  @override
  bool operator ==(Object other) => other is PublishResult && other.msgId == msgId && other.delivered == delivered;

  @override
  int get hashCode => Object.hash(msgId, delivered);
}

/// [code] is the server's: 401 token, 403 not allowed, 410 could not replay, 413 too large, 429 slow down, 503 try again. 0 is a problem on this side.
class RealtimeException implements Exception {
  const RealtimeException(this.message, [this.code = 0, this.reason]);
  final String message;
  final int code;

  /// For a failed [ZapiackRealtime.request]: the service's own word for it: `forbidden`, `invalid`, `no_route`, `timeout`, `rate_limited` or `internal`.
  final String? reason;

  @override
  String toString() => 'RealtimeException($code): $message';
}

/// One open line to the server. The default is a `dart:io` WebSocket; tests give a fake.
abstract class RealtimeSocket {
  /// Text frames from the server. Completes when the line closes.
  Stream<String> get frames;
  void send(String text);
  void close();

  /// The code the line closed with, once it has (a custom code such as 4403 is visible here).
  int? get closeCode;
}

typedef RealtimeSocketFactory = Future<RealtimeSocket> Function(Uri url);

class IoRealtimeSocket implements RealtimeSocket {
  IoRealtimeSocket._(this._ws);
  final WebSocket _ws;

  static Future<RealtimeSocket> connect(Uri url) async => IoRealtimeSocket._(await WebSocket.connect(url.toString()));

  @override
  Stream<String> get frames => _ws.where((e) => e is String).cast<String>();
  @override
  void send(String text) => _ws.add(text);
  @override
  void close() => unawaited(_ws.close(1000));
  @override
  int? get closeCode => _ws.closeCode;
}

typedef TokenProvider = Future<String> Function();

class ZapiackRealtime {
  ZapiackRealtime({
    required this.getToken,
    Uri? url,
    this.heartbeat = const Duration(seconds: 25),
    this.backoffMin = const Duration(seconds: 1),
    this.backoffMax = const Duration(seconds: 30),
    this.ackTimeout = const Duration(seconds: 10),
    RealtimeSocketFactory? socketFactory,
    DateTime Function()? clock,
  })  : url = url ?? Uri.parse(defaultUrl),
        _connect = socketFactory ?? IoRealtimeSocket.connect,
        _now = clock ?? DateTime.now;

  static const defaultUrl = 'wss://rt.zapiack.com';
  static const _maxOutbox = 100;

  /// Asks your server for a token. Called on every connect, so an expired token is replaced.
  final TokenProvider getToken;
  final Uri url;
  final Duration heartbeat;
  final Duration backoffMin;
  final Duration backoffMax;
  final Duration ackTimeout;
  final RealtimeSocketFactory _connect;
  final DateTime Function() _now;

  RealtimeState _state = RealtimeState.idle;
  String? _connectionId;
  RealtimeSocket? _socket;
  StreamSubscription<String>? _reader;
  int _generation = 0;
  bool _wanted = false;
  bool _refused = false;
  int _attempt = 0;
  DateTime _heard = DateTime.fromMillisecondsSinceEpoch(0);
  int _ackSeq = 0;
  int _nextId = 0;
  Timer? _beat;
  Timer? _retry;
  final List<String> _outbox = [];
  final Map<String, _Sub> _subs = {};
  final Map<String, ({Completer<PublishResult> done, Timer timer})> _waiting = {};
  final Map<String, ({Completer<Map<String, dynamic>> done, Timer timer})> _requests = {};
  int _rpcSeq = 0;
  final List<Completer<void>> _first = [];
  final Map<String, Map<String, PresenceMember>> _members = {};
  final Map<String, StreamController<({String action, PresenceMember member})>> _presence = {};
  final _states = StreamController<RealtimeState>.broadcast();
  final _errors = StreamController<RealtimeException>.broadcast();

  RealtimeState get state => _state;

  /// This connection's id, once connected. Other members use it to signal you.
  String? get connectionId => _connectionId;
  Stream<RealtimeState> get states => _states.stream;
  Stream<RealtimeException> get errors => _errors.stream;

  /// Connects and completes once the server has said hello (or throws if the project refuses this client). It then keeps itself
  /// connected until [disconnect].
  Future<void> connect() {
    if (_state == RealtimeState.connected) return Future.value();
    _wanted = true;
    final c = Completer<void>();
    _first.add(c);
    if (_socket == null && _retry == null && _first.length == 1) unawaited(_open());
    return c.future;
  }

  /// Leaves for good: closes the line and drops what was waiting. Subscriptions stay, for a later [connect].
  void disconnect() {
    _wanted = false;
    _generation++;
    _retry?.cancel();
    _retry = null;
    _stopBeat();
    unawaited(_reader?.cancel());
    _reader = null;
    _socket?.close();
    _socket = null;
    _connectionId = null;
    _failAll(const RealtimeException('Disconnected.'));
    _outbox.clear();
    _set(RealtimeState.closed);
  }

  /// Messages on [channel], now and after reconnects. Joins the channel when the first listener arrives and leaves it when the
  /// last one cancels. Pass [resumeFrom] (a message id) to replay what came after it.
  Stream<RealtimeMessage> subscribe(String channel, {String? resumeFrom}) {
    late StreamController<RealtimeMessage> controller;
    final id = ++_nextId;
    controller = StreamController<RealtimeMessage>(
      sync: true,
      onListen: () {
        final fresh = !_subs.containsKey(channel);
        final sub = _subs.putIfAbsent(channel, () => _Sub(resumeFrom));
        sub.listeners[id] = controller;
        if (fresh) _enqueue(_subscribeFrame(channel, sub.cursor));
      },
      onCancel: () {
        final sub = _subs[channel];
        if (sub == null) return;
        sub.listeners.remove(id);
        if (sub.listeners.isEmpty) {
          _subs.remove(channel);
          _members.remove(channel);
          unawaited(_presence.remove(channel)?.close());
          _enqueue({'op': 'unsubscribe', 'channel': channel});
        }
      },
    );
    return controller.stream;
  }

  /// Sends a message and completes when the server confirms, or throws with its reason. [persist] keeps it in the channel's
  /// history so clients that were away can replay it.
  Future<PublishResult> publish(String channel, Object? data, {String event = 'message', bool persist = false}) {
    final ackId = 'a${++_ackSeq}';
    final done = Completer<PublishResult>();
    final timer = Timer(ackTimeout, () {
      if (_waiting.remove(ackId) != null) done.completeError(const RealtimeException('The server did not confirm in time.'));
    });
    _waiting[ackId] = (done: done, timer: timer);
    final ok = _enqueue({'op': 'publish', 'channel': channel, 'event': event, 'data': data, 'persist': persist, 'ackId': ackId});
    if (!ok) _settle(ackId)?.completeError(const RealtimeException('Could not send: too many messages waiting for a connection.', 429));
    return done.future;
  }

  /// Sends without waiting for a confirmation.
  void publishWithoutAck(String channel, Object? data, {String event = 'message', bool persist = false}) {
    _enqueue({'op': 'publish', 'channel': channel, 'event': event, 'data': data, 'persist': persist});
  }

  /// Sends to one connection in a channel you are subscribed to. Used for peer-to-peer setup such as WebRTC.
  void signal(String channel, String to, String event, Object? data) => _enqueue({'op': 'signal', 'channel': channel, 'to': to, 'event': event, 'data': data});

  /// Asks a Zapiack service something over this connection and waits for the answer: the way a call client talks to the media
  /// server. Needs a token minted for a call. It is never queued for later: if the line is down it fails at once, because an answer
  /// to an old question is worse than none. Throws a [RealtimeException] whose [RealtimeException.reason] is the service's word.
  Future<Map<String, dynamic>> request(String method, [Map<String, Object?> data = const {}]) {
    final s = _socket;
    if (s == null || _state != RealtimeState.connected) return Future.error(const RealtimeException('Not connected.', 0, 'no_route'));
    final id = 'r${++_rpcSeq}';
    final done = Completer<Map<String, dynamic>>();
    final timer = Timer(ackTimeout + const Duration(seconds: 2), () {
      if (_requests.remove(id) != null) done.completeError(const RealtimeException('The server did not answer in time.', 0, 'timeout'));
    });
    _requests[id] = (done: done, timer: timer);
    s.send(jsonEncode({'op': 'rpc', 'method': method, 'correlationId': id, 'data': data}));
    return done.future;
  }

  /// Presence in a channel you are subscribed to.
  RealtimePresence presence(String channel) => RealtimePresence._(this, channel);

  // ───────────────────────────── internals

  void _set(RealtimeState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  void _fail(RealtimeException e) {
    if (!_errors.isClosed) _errors.add(e);
  }

  Completer<PublishResult>? _settle(String ackId) {
    final w = _waiting.remove(ackId);
    w?.timer.cancel();
    return w?.done;
  }

  void _failAll(RealtimeException e) {
    for (final id in _waiting.keys.toList()) {
      _settle(id)?.completeError(e);
    }
    _failRequests(e);
  }

  void _failRequests(RealtimeException e) {
    for (final id in _requests.keys.toList()) {
      final r = _requests.remove(id);
      r?.timer.cancel();
      r?.done.completeError(e);
    }
  }

  static Map<String, Object?> _subscribeFrame(String channel, String? cursor) => {'op': 'subscribe', 'channel': channel, 'resumeFrom': ?cursor};

  /// Writes now if the line is open, otherwise keeps it (a short while) for when it is. False when there is no room.
  bool _enqueue(Map<String, Object?> frame) {
    final text = jsonEncode(frame);
    final s = _socket;
    if (s != null && _state == RealtimeState.connected) {
      s.send(text);
      return true;
    }
    // A subscribe is re-sent from the subscriptions when the line opens, so queueing it too would only say it twice.
    final op = frame['op'];
    if (op == 'subscribe' || op == 'unsubscribe') return true;
    if (_outbox.length >= _maxOutbox) return false;
    _outbox.add(text);
    return true;
  }

  Future<void> _open() async {
    if (!_wanted) return;
    final gen = ++_generation;
    _set(_attempt == 0 && _state != RealtimeState.reconnecting ? RealtimeState.connecting : RealtimeState.reconnecting);
    String token;
    try {
      token = await getToken();
      if (token.isEmpty) throw const RealtimeException('getToken returned no token.');
    } catch (e) {
      if (!_wanted || gen != _generation) return;
      _fail(RealtimeException('Could not get a token: ${e is RealtimeException ? e.message : e}'));
      return _later();
    }
    if (!_wanted || gen != _generation) return;
    final uri = url.replace(path: '/', queryParameters: {'token': token});
    RealtimeSocket s;
    try {
      s = await _connect(uri);
    } catch (e) {
      if (!_wanted || gen != _generation) return;
      _fail(RealtimeException('Could not open the connection: $e'));
      return _later();
    }
    if (!_wanted || gen != _generation) {
      s.close();
      return;
    }
    _socket = s;
    _heard = _now();
    _reader = s.frames.listen((t) => _onFrame(t, gen), onDone: () => _onClose(s.closeCode ?? 1006, gen), onError: (_) => _onClose(1006, gen), cancelOnError: true);
  }

  void _onFrame(String text, int gen) {
    if (gen != _generation) return;
    _heard = _now();
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final f = decoded;
    switch (f['op']) {
      case 'hello':
        _connectionId = f['connId'] as String?;
        _attempt = 0;
        _set(RealtimeState.connected);
        for (final e in _subs.entries) {
          _socket?.send(jsonEncode(_subscribeFrame(e.key, e.value.cursor)));
        }
        for (final t in _outbox) {
          _socket?.send(t);
        }
        _outbox.clear();
        _startBeat(gen);
        final waiters = List.of(_first);
        _first.clear();
        for (final c in waiters) {
          if (!c.isCompleted) c.complete();
        }
      case 'message':
        _onMessage(f);
      case 'ack':
        _settle(f['ackId'] as String? ?? '')?.complete(PublishResult(msgId: f['msgId'] as String? ?? '', delivered: (f['delivered'] as num?)?.toInt() ?? 0));
      case 'error':
        if (f['fatal'] == true) _refused = true;
        final e = RealtimeException(f['message'] as String? ?? 'Error', (f['code'] as num?)?.toInt() ?? 0);
        final ref = f['ref'] as String?;
        final waiting = ref == null ? null : _settle(ref);
        if (waiting != null) {
          waiting.completeError(e);
        } else {
          _fail(e);
        }
      case 'rpc.result':
      case 'rpc.error':
        final r = _requests.remove(f['correlationId']?.toString() ?? '');
        if (r == null) return;
        r.timer.cancel();
        if (f['op'] == 'rpc.result') {
          final data = f['data'];
          r.done.complete(data is Map<String, dynamic> ? data : <String, dynamic>{});
        } else {
          r.done.completeError(RealtimeException(f['message'] as String? ?? 'The request failed.', 0, f['code']?.toString() ?? 'internal'));
        }
      case 'presence.members':
        final map = <String, PresenceMember>{};
        for (final m in (f['members'] as List? ?? const [])) {
          final member = _member(m);
          if (member != null) map[member.connId] = member;
        }
        _members[f['channel'] as String] = map;
      case 'resume.failed':
        // Too long away to replay: the app should reload what it needs over REST. Say so rather than hide the gap.
        _fail(RealtimeException('Missed messages on ${f['channel']} could not be replayed. Reload its history.', 410));
    }
  }

  void _onMessage(Map<String, dynamic> f) {
    final channel = f['channel'] as String? ?? '';
    final msgId = f['msgId'] as String? ?? '';
    final event = f['event'] as String? ?? '';
    if (event.startsWith('presence.')) return _onPresence(channel, event, f);
    final sub = _subs[channel];
    if (sub == null) return;
    if (f['persisted'] == true) {
      // Seen already (a replay overlapping a live message): once is enough.
      final cursor = sub.cursor;
      if (cursor != null && !isAfter(msgId, cursor)) return;
      sub.cursor = msgId;
    }
    final message = RealtimeMessage(msgId: msgId, ts: f['ts'] as num? ?? 0, channel: channel, event: event, data: f['data'], from: f['from'] as String?, replayed: f['replayed'] == true);
    for (final c in sub.listeners.values.toList()) {
      if (!c.isClosed) c.add(message);
    }
  }

  void _onPresence(String channel, String event, Map<String, dynamic> f) {
    final m = _member(f['data']);
    if (m == null) return;
    final action = event.substring('presence.'.length);
    final map = _members.putIfAbsent(channel, () => {});
    if (action == 'leave') {
      map.remove(m.connId);
    } else {
      map[m.connId] = m;
    }
    final c = _presence[channel];
    if (c != null && !c.isClosed) c.add((action: action, member: m));
  }

  static PresenceMember? _member(Object? o) {
    if (o is! Map) return null;
    final id = o['connId'];
    return id is String ? PresenceMember(connId: id, user: o['user'] as String?, data: o['data']) : null;
  }

  void _startBeat(int gen) {
    _stopBeat();
    _heard = _now();
    _beat = Timer.periodic(heartbeat, (_) {
      if (gen != _generation) return;
      // Nothing heard for two beats: the line is dead even if the socket says otherwise. Drop it and start again.
      if (_now().difference(_heard) > heartbeat * 2) {
        _socket?.close();
        _onClose(4000, gen);
      } else {
        _socket?.send('{"op":"ping"}');
      }
    });
  }

  void _stopBeat() {
    _beat?.cancel();
    _beat = null;
  }

  void _onClose(int code, int gen) {
    if (gen != _generation) return;
    _generation++;
    _failRequests(const RealtimeException('The connection dropped.', 0, 'no_route'));
    unawaited(_reader?.cancel());
    _reader = null;
    _socket = null;
    _stopBeat();
    _connectionId = null;
    if (!_wanted) return;
    // 4403, or an error the server marked fatal: the project switched this client off, and trying again would only be refused again.
    if (code == 4403 || _refused) {
      _refused = false;
      _wanted = false;
      const e = RealtimeException('The project does not allow this connection.', 403);
      _failAll(e);
      final waiters = List.of(_first);
      _first.clear();
      for (final c in waiters) {
        if (!c.isCompleted) c.completeError(e);
      }
      _set(RealtimeState.closed);
      return;
    }
    _set(RealtimeState.reconnecting);
    // 4401 means the token was refused or ran out: fetching a new one is exactly what the next attempt does, so there is no pause.
    _later(force: (code == 4401 || code == 1012) ? Duration.zero : null);
  }

  void _later({Duration? force}) {
    _retry?.cancel();
    _attempt++;
    final ceilingMs = min(backoffMax.inMilliseconds, backoffMin.inMilliseconds * (1 << min(_attempt - 1, 20)));
    // Full jitter, so a node that restarts is not met by every client at the same moment.
    final wait = force ?? Duration(milliseconds: backoffMin.inMilliseconds + (Random().nextDouble() * (ceilingMs - backoffMin.inMilliseconds)).round());
    _set(RealtimeState.reconnecting);
    _retry = Timer(wait, () {
      _retry = null;
      unawaited(_open());
    });
  }
}

/// Presence in one channel.
class RealtimePresence {
  RealtimePresence._(this._rt, this.channel);
  final ZapiackRealtime _rt;
  final String channel;

  void enter([Object? data]) => _rt._enqueue({'op': 'presence.enter', 'channel': channel, 'data': data});
  void update(Object? data) => _rt._enqueue({'op': 'presence.update', 'channel': channel, 'data': data});
  void leave() => _rt._enqueue({'op': 'presence.leave', 'channel': channel});

  /// Who is here now, as last told.
  List<PresenceMember> get members => (_rt._members[channel]?.values ?? const <PresenceMember>[]).toList();

  /// "enter", "update" and "leave" as they happen.
  Stream<({String action, PresenceMember member})> get changes => _rt._presence.putIfAbsent(channel, () => StreamController.broadcast(sync: true)).stream;
}

class _Sub {
  _Sub(this.cursor);

  /// The last persisted message seen: where to resume from.
  String? cursor;
  final Map<int, StreamController<RealtimeMessage>> listeners = {};
}

/// Message ids are `milliseconds-sequence`; this orders them.
@visibleForTesting
bool isAfter(String a, String b) {
  (int, int) parts(String s) {
    final p = s.split('-').map((x) => int.tryParse(x) ?? 0).toList();
    return (p.isNotEmpty ? p[0] : 0, p.length > 1 ? p[1] : 0);
  }

  final (am, aseq) = parts(a);
  final (bm, bseq) = parts(b);
  return am > bm || (am == bm && aseq > bseq);
}
