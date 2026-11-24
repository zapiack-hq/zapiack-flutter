// A call: join a room, send the microphone, camera and screen, and receive everyone else's.
//
// Your server makes the room and a token for each person (`POST /v1/calls/rooms`, `POST /v1/calls/tokens`, or `POST /v1/calls` to
// ring someone) and gives the token to the app, so the API key never reaches the phone.
//
//     final call = ZapiackCall(getToken: () => myServer.callToken());
//     call.tracks.listen((t) => show(t));
//     await call.join();
//     await call.enableMicrophone();
//     await call.enableCamera();
//
// What a person may send comes from their token: a listener can only receive. The same signalling and the same server requests as the
// web and React Native clients.
library;

import 'dart:async';

import 'call_media.dart';
import 'mediasoup/mediasoup.dart';
import 'realtime.dart';

/// What a track is: a microphone, a camera, or a shared screen.
enum TrackSource { audio, video, screen }

enum CallRole { host, speaker, listener }

enum CallState { idle, joining, joined, reconnecting, closed }

CallRole _role(Object? v) => CallRole.values.firstWhere((r) => r.name == v, orElse: () => CallRole.speaker);
TrackSource _source(Object? v) => TrackSource.values.firstWhere((s) => s.name == v, orElse: () => TrackSource.video);

class CallPeer {
  const CallPeer(this.identity, this.role);
  final String identity;
  final CallRole role;
}

/// Someone else's audio, video or screen. [stream] is the engine's stream (flutter_webrtc's `MediaStream`) to give a video view;
/// audio plays by itself.
class RemoteTrack {
  const RemoteTrack({required this.identity, required this.source, required this.track, required this.stream, required this.producerId});
  final String identity;
  final TrackSource source;
  final MediaTrack track;
  final Object stream;

  /// The sender's track id: the same one [TrackEnded] and [TrackPaused] carry.
  final String producerId;
}

class TrackEnded {
  const TrackEnded(this.identity, this.source, this.producerId);
  final String identity;
  final TrackSource source;
  final String producerId;
}

class TrackPaused {
  const TrackPaused(this.identity, this.source, this.producerId, this.paused);
  final String identity;
  final TrackSource source;
  final String producerId;
  final bool paused;
}

class CallEnded {
  const CallEnded(this.reason);
  final String reason;
}

class CallStats {
  const CallStats({required this.identity, required this.source, required this.bytesReceived, required this.packetsReceived, required this.packetsLost, required this.jitter});
  final String identity;
  final TrackSource source;
  final int bytesReceived;
  final int packetsReceived;
  final int packetsLost;
  final double jitter;
}

class CallException implements Exception {
  const CallException(this.message, [this.reason]);
  final String message;

  /// The service's word for it when the server refused: `forbidden`, `invalid`, `rate_limited`...
  final String? reason;
  @override
  String toString() => 'CallException: $message';
}

/// The signalling line, as a call uses it. [ZapiackRealtime] is the real one; tests give a fake.
abstract class CallSignal {
  Future<void> connect();
  void disconnect();
  Future<Map<String, dynamic>> request(String method, [Map<String, Object?> data]);
  Stream<RealtimeMessage> subscribe(String channel);
  Stream<RealtimeState> get states;
}

class RealtimeSignal implements CallSignal {
  RealtimeSignal(this.rt);
  final ZapiackRealtime rt;
  @override
  Future<void> connect() => rt.connect();
  @override
  void disconnect() => rt.disconnect();
  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, Object?> data = const {}]) async {
    try {
      return await rt.request(method, data);
    } on RealtimeException catch (e) {
      throw CallException(e.message, e.reason);
    }
  }

  @override
  Stream<RealtimeMessage> subscribe(String channel) => rt.subscribe(channel);
  @override
  Stream<RealtimeState> get states => rt.states;
}

class _Consumed {
  _Consumed(this.consumer, this.identity, this.source);
  final Consumer consumer;
  final String identity;
  final TrackSource source;
}

class ZapiackCall {
  /// [getToken] asks your server for a call token. [signal], [factory] and [media] are for tests; the defaults are the real ones.
  ZapiackCall({
    required Future<String> Function() getToken,
    Uri? url,
    this.forceTcp = false,
    this.frontCamera = true,
    CallSignal? signal,
    required LinkFactory factory,
    required CallMedia media,
    this.disconnectedGrace = const Duration(seconds: 4),
    this.resyncEvery = const Duration(seconds: 30),
  })  : _signal = signal ?? RealtimeSignal(ZapiackRealtime(getToken: getToken, url: url)),
        // ignore: prefer_initializing_formals
        _media = media,
        _device = Device(factory);

  /// Send and receive over TCP only, for networks that block UDP.
  final bool forceTcp;
  bool frontCamera;

  /// How long a path that reports `disconnected` gets to come back before it is restarted. A phone changing from Wi-Fi to mobile data
  /// goes through it.
  final Duration disconnectedGrace;

  /// How often the call asks the server who is in the room and catches up on anything it missed. [Duration.zero] turns it off.
  final Duration resyncEvery;

  final CallSignal _signal;
  final CallMedia _media;
  final Device _device;
  final _tracks = StreamController<RemoteTrack>.broadcast(sync: true);
  final _trackEnded = StreamController<TrackEnded>.broadcast(sync: true);
  final _paused = StreamController<TrackPaused>.broadcast(sync: true);
  final _peerJoined = StreamController<CallPeer>.broadcast(sync: true);
  final _peerLeft = StreamController<String>.broadcast(sync: true);
  final _ended = StreamController<CallEnded>.broadcast(sync: true);
  final _errors = StreamController<CallException>.broadcast(sync: true);
  final _stateChanges = StreamController<CallState>.broadcast(sync: true);

  Transport? _sendT;
  Transport? _recvT;
  final Map<TrackSource, Producer> _producers = {};
  final Map<String, _Consumed> _consumers = {};
  final Map<String, CallPeer> _peers = {};
  final Set<String> _fetching = {};
  final Map<String, Timer> _lapse = {};
  Map<String, dynamic>? _joined;
  StreamSubscription<RealtimeMessage>? _roomSub;
  StreamSubscription<RealtimeState>? _stateSub;
  CallState _state = CallState.idle;
  bool _wasConnected = false;
  bool _resyncing = false;
  Timer? _resyncTimer;
  bool _speaker = false;

  /// Someone's track arrived.
  Stream<RemoteTrack> get tracks => _tracks.stream;

  /// Someone stopped sending a track, or left.
  Stream<TrackEnded> get trackEnded => _trackEnded.stream;

  /// Someone muted or unmuted a track. The track stays; what it carries is silence or a frozen picture.
  Stream<TrackPaused> get paused => _paused.stream;
  Stream<CallPeer> get peerJoined => _peerJoined.stream;
  Stream<String> get peerLeft => _peerLeft.stream;

  /// The room was ended, or the line was lost for good. The call is already closed when this fires.
  Stream<CallEnded> get ended => _ended.stream;

  /// A problem worth showing: a track that could not be played, or a refused request.
  Stream<CallException> get errors => _errors.stream;
  Stream<CallState> get stateChanges => _stateChanges.stream;

  CallState get state => _state;
  CallRole? get role => _joined == null ? null : _role(_joined!['role']);
  String? get roomId => _joined?['roomId'] as String?;
  List<CallPeer> get members => _peers.values.toList();

  /// What is being sent now.
  List<TrackSource> get sending => _producers.keys.toList();

  void _set(CallState s) {
    _state = s;
    if (!_stateChanges.isClosed) _stateChanges.add(s);
  }

  void _emit<T>(StreamController<T> c, T v) {
    if (!c.isClosed) c.add(v);
  }

  /// Connects, joins the room the token is for, and starts receiving what the others are sending.
  Future<({CallRole role, String roomId, List<CallPeer> members})> join() async {
    if (_state == CallState.joined) return (role: role!, roomId: roomId!, members: members);
    _set(CallState.joining);
    try {
      await _signal.connect();
      final reply = await _signal.request('media.join');
      _joined = reply;
      if (!_device.loaded) await _device.load((reply['routerRtpCapabilities'] as Map).cast<String, dynamic>());
      _roomSub = _signal.subscribe('call:${reply['roomId']}').listen(_onRoomEvent);
      _stateSub = _signal.states.listen((s) => unawaited(_onLine(s)));
      _wasConnected = true;
      if (_speaker) unawaited(_media.setSpeaker(true));
      // Someone may have started sending between the answer and the subscribe. Joining again is harmless and returns who is here now.
      final fresh = await _signal.request('media.join');
      await _reconcile(((fresh['peers'] ?? const []) as List).cast<Map<String, dynamic>>());
      _set(CallState.joined);
      _startResync();
      return (role: role!, roomId: roomId!, members: members);
    } catch (e) {
      await _teardown();
      _set(CallState.closed);
      rethrow;
    }
  }

  /// Turns the microphone on and sends it.
  Future<MediaTrack> enableMicrophone([MediaTrack? track]) async {
    final t = track ?? await _media.microphone();
    await _send(TrackSource.audio, t);
    return t;
  }

  /// Turns the camera on and sends it. The front one, unless [frontCamera] is false.
  Future<MediaTrack> enableCamera([MediaTrack? track]) async {
    final t = track ?? await _media.camera(front: frontCamera);
    await _send(TrackSource.video, t);
    return t;
  }

  /// Shares the phone's screen. Android needs a foreground service for screen capture and iOS a broadcast extension: see the README.
  Future<MediaTrack> shareScreen([MediaTrack? track]) async {
    final t = track ?? await _media.screen();
    t.onEnded = () => unawaited(stop(TrackSource.screen));
    await _send(TrackSource.screen, t);
    return t;
  }

  /// Mutes or unmutes what is being sent. Nothing is sent while muted, and the others are told.
  Future<void> setMuted(TrackSource source, bool muted) async {
    final p = _producers[source];
    if (p == null) return;
    if (muted) {
      p.pause();
    } else {
      p.resume();
    }
    await _signal.request(muted ? 'media.pauseProducer' : 'media.resumeProducer', {'producerId': p.id});
  }

  bool isMuted(TrackSource source) => _producers[source]?.paused ?? false;

  /// Flips between the front and back camera while the camera is on, without interrupting what is being sent.
  Future<void> switchCamera() async {
    final p = _producers[TrackSource.video];
    if (p == null) throw const CallException('The camera is not on.');
    await _media.switchCamera(p.track);
    frontCamera = !frontCamera;
  }

  /// Plays sound through the loudspeaker (true) or the earpiece (false). Remembered across a reconnect.
  Future<void> setSpeaker(bool on) {
    _speaker = on;
    return _media.setSpeaker(on);
  }

  /// Stops sending a track and lets go of the device (the camera light goes off).
  Future<void> stop(TrackSource source) async {
    final p = _producers.remove(source);
    if (p == null) return;
    p.close();
    await _signal.request('media.closeProducer', {'producerId': p.id}).then<void>((_) {}, onError: (_) {});
  }

  /// What is arriving now, one entry per track: bytes, packets, losses and jitter. For a quality indicator, or to see that media is
  /// really flowing.
  Future<List<CallStats>> stats() async {
    final out = <CallStats>[];
    for (final c in _consumers.values) {
      var bytes = 0, packets = 0, lost = 0;
      var jitter = 0.0;
      for (final r in await c.consumer.getStats()) {
        if (r['type'] != 'inbound-rtp') continue;
        bytes += (r['bytesReceived'] as num? ?? 0).toInt();
        packets += (r['packetsReceived'] as num? ?? 0).toInt();
        lost += (r['packetsLost'] as num? ?? 0).toInt();
        final j = (r['jitter'] as num? ?? 0).toDouble();
        if (j > jitter) jitter = j;
      }
      out.add(CallStats(identity: c.identity, source: c.source, bytesReceived: bytes, packetsReceived: packets, packetsLost: lost, jitter: jitter));
    }
    return out;
  }

  /// Everything the engine reports about each received track, as it reports it. For diagnosing; [stats] is the summary.
  Future<Map<String, List<Map<String, dynamic>>>> rawStats() async => {
        for (final e in _consumers.entries) '${e.value.identity}:${e.value.source.name}': await e.value.consumer.getStats(),
      };

  /// Everything the engine reports about the connection that receives (`recv`) or the one that sends (`send`): candidate pairs,
  /// transport, streams. For diagnosing.
  Future<List<Map<String, dynamic>>> connectionStats({bool receiving = true}) async => (receiving ? _recvT : _sendT)?.getStats() ?? const [];

  /// Leaves the room and lets go of the camera, the microphone and the connection.
  Future<void> leave() async {
    if (_state == CallState.closed || _state == CallState.idle) return;
    await _signal.request('media.leave').then<void>((_) {}, onError: (_) {});
    await _teardown();
    _set(CallState.closed);
  }

  /// Leaves, and closes the streams. The call cannot be used again.
  Future<void> dispose() async {
    await leave();
    for (final c in [_tracks, _trackEnded, _paused, _peerJoined, _peerLeft, _ended, _errors, _stateChanges]) {
      await c.close();
    }
  }

  // ───────────────────────────── transports

  Future<Transport> _transport(String direction) async {
    final held = direction == 'send' ? _sendT : _recvT;
    if (held != null && !held.closed) return held;
    final info = await _signal.request('media.createTransport', {'direction': direction});
    final t = (direction == 'send' ? _device.createSendTransport : _device.createRecvTransport)(TransportOptions(
      id: info['id'] as String,
      iceParameters: (info['iceParameters'] as Map).cast<String, dynamic>(),
      iceCandidates: (info['iceCandidates'] as List),
      dtlsParameters: (info['dtlsParameters'] as Map).cast<String, dynamic>(),
      iceServers: [for (final s in ((_joined?['iceServers'] ?? const []) as List)) (s as Map).cast<String, dynamic>()],
      iceTransportPolicy: forceTcp ? 'relay' : 'all',
    ));
    t.onConnect = (dtls) async {
      await _signal.request('media.connectTransport', {'transportId': t.id, 'dtlsParameters': dtls});
    };
    if (direction == 'send') {
      t.onProduce = ({required kind, required rtpParameters, required appData}) async {
        final source = appData['source'] as String? ?? kind;
        final r = await _signal.request('media.produce', {'transportId': t.id, 'kind': source, 'rtpParameters': rtpParameters});
        return r['id'] as String;
      };
    }
    t.onConnectionStateChange = (s) => _onTransportState(t, s);
    if (direction == 'send') {
      _sendT = t;
    } else {
      _recvT = t;
    }
    return t;
  }

  /// A path that failed is restarted with fresh ICE parameters from the server. One that is only `disconnected` (a phone moving from
  /// Wi-Fi to mobile data) gets a few seconds to recover by itself first.
  void _onTransportState(Transport t, String s) {
    _lapse.remove(t.id)?.cancel();
    if (s == 'failed') {
      unawaited(_restartIce(t));
    } else if (s == 'disconnected') {
      _lapse[t.id] = Timer(disconnectedGrace, () {
        _lapse.remove(t.id);
        if (!t.closed) unawaited(_restartIce(t));
      });
    }
  }

  Future<void> _restartIce(Transport t) async {
    try {
      final r = await _signal.request('media.restartIce', {'transportId': t.id});
      await t.restartIce((r['iceParameters'] as Map).cast<String, dynamic>());
    } catch (e) {
      _emit(_errors, e is CallException ? e : CallException('$e'));
    }
  }

  // ───────────────────────────── sending

  Future<void> _send(TrackSource source, MediaTrack track) async {
    if (_state != CallState.joined) throw const CallException('Join the call first.');
    if (role == CallRole.listener) throw const CallException('Your role in this call can only listen.', 'forbidden');
    // Sending the same thing again replaces it: the old track is closed first.
    if (_producers.containsKey(source)) await stop(source);
    final t = await _transport('send');
    final producer = await t.produce(
      track: track,
      appData: {'source': source.name},
      maxBitrate: switch (source) { TrackSource.audio => 64000, TrackSource.screen => 2500000, TrackSource.video => 1200000 },
      codecOptions: source == TrackSource.audio ? {'opusDtx': true, 'opusFec': true} : null,
    );
    track.onEnded = () => unawaited(stop(source));
    _producers[source] = producer;
  }

  // ───────────────────────────── receiving

  Future<void> _reconcile(List<Map<String, dynamic>> peers) async {
    final here = {for (final p in peers) p['identity'] as String};
    for (final p in peers) {
      final id = p['identity'] as String;
      if (!_peers.containsKey(id)) {
        final peer = CallPeer(id, _role(p['role']));
        _peers[id] = peer;
        _emit(_peerJoined, peer);
      }
    }
    for (final id in _peers.keys.toList()) {
      if (!here.contains(id)) {
        _peers.remove(id);
        _dropFrom(id);
        _emit(_peerLeft, id);
      }
    }
    final live = {
      for (final p in peers)
        for (final x in ((p['producers'] ?? const []) as List).cast<Map<String, dynamic>>()) x['id'] as String,
    };
    for (final e in _consumers.entries.toList()) {
      if (!live.contains(e.key)) _endTrack(e.key, e.value.identity, e.value.source);
    }
    for (final p in peers) {
      for (final pr in ((p['producers'] ?? const []) as List).cast<Map<String, dynamic>>()) {
        await _consume(pr['id'] as String, p['identity'] as String, _source(pr['kind']), pr['paused'] == true);
      }
    }
  }

  Future<void> _consume(String producerId, String identity, TrackSource kind, [bool paused = false]) async {
    if (_consumers.containsKey(producerId) || _fetching.contains(producerId)) return;
    _fetching.add(producerId);
    try {
      final t = await _transport('recv');
      final r = await _signal.request('media.consume', {'producerId': producerId, 'rtpCapabilities': _device.rtpCapabilities});
      final source = _source(r['source']);
      final who = r['identity'] as String;
      final consumer = await t.consume(
        id: r['id'] as String,
        producerId: r['producerId'] as String,
        kind: r['kind'] as String,
        rtpParameters: (r['rtpParameters'] as Map).cast<String, dynamic>(),
        appData: {'source': source.name},
      );
      _consumers[producerId] = _Consumed(consumer, who, source);
      // The server made it paused so nothing is lost before the player is ready; it starts now.
      await _signal.request('media.resumeConsumer', {'consumerId': consumer.id});
      final stream = await _media.streamOf(consumer.track);
      _emit(_tracks, RemoteTrack(identity: who, source: source, track: consumer.track, stream: stream, producerId: producerId));
      if (paused) _emit(_paused, TrackPaused(who, source, producerId, true));
      consumer.onTransportClose = () => _endTrack(producerId, who, source);
    } catch (e) {
      _emit(_errors, e is CallException ? e : CallException("Could not play $identity's ${kind.name}: $e"));
    } finally {
      _fetching.remove(producerId);
    }
  }

  void _endTrack(String producerId, String identity, TrackSource source) {
    final c = _consumers.remove(producerId);
    if (c == null) return;
    c.consumer.close();
    _emit(_trackEnded, TrackEnded(identity, source, producerId));
  }

  void _dropFrom(String identity) {
    for (final e in _consumers.entries.toList()) {
      if (e.value.identity == identity) _endTrack(e.key, e.value.identity, e.value.source);
    }
  }

  void _onRoomEvent(RealtimeMessage m) {
    final d = m.data is Map ? (m.data as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final me = _joined?['identity'];
    switch (m.event) {
      case 'peerJoined':
        final id = d['identity'] as String?;
        if (id != null && id != me && !_peers.containsKey(id)) {
          final peer = CallPeer(id, _role(d['role']));
          _peers[id] = peer;
          _emit(_peerJoined, peer);
        }
      case 'peerLeft':
        final id = d['identity'] as String?;
        if (id != null && _peers.remove(id) != null) {
          _dropFrom(id);
          _emit(_peerLeft, id);
        }
      case 'newProducer':
        if (d['identity'] != me) unawaited(_consume(d['producerId'] as String, d['identity'] as String, _source(d['kind'])));
      case 'producerClosed':
        final c = _consumers[d['producerId']];
        if (c != null) _endTrack(d['producerId'] as String, c.identity, c.source);
      case 'producerPaused':
        final c = _consumers[d['producerId']];
        if (c != null) _emit(_paused, TrackPaused(c.identity, c.source, d['producerId'] as String, d['paused'] == true));
      case 'roomEnded' || 'roomEnding':
        final reason = '${d['reason'] ?? 'ended'}';
        unawaited(_teardown().then((_) {
          _set(CallState.closed);
          _emit(_ended, CallEnded(reason));
        }));
    }
  }

  // ───────────────────────────── the line coming and going

  /// Room events travel over best-effort publish and subscribe, so a call does not rely on every one arriving: now and then it asks the
  /// server who is in the room and what they are sending, and catches up on anything it missed.
  void _startResync() {
    if (_resyncTimer != null || resyncEvery == Duration.zero) return;
    _resyncTimer = Timer.periodic(resyncEvery, (_) => unawaited(_resync()));
  }

  Future<void> _resync() async {
    if (_state != CallState.joined || _resyncing) return;
    _resyncing = true;
    try {
      final fresh = await _signal.request('media.join');
      if (_state == CallState.joined) await _reconcile(((fresh['peers'] ?? const []) as List).cast<Map<String, dynamic>>());
    } catch (_) {
      // A failed question is asked again next time; a line that is really gone is handled by _onLine.
    } finally {
      _resyncing = false;
    }
  }

  /// The socket dropped and came back: take the place in the room again and see what changed while away.
  Future<void> _onLine(RealtimeState s) async {
    if (s == RealtimeState.reconnecting && _state == CallState.joined) _set(CallState.reconnecting);
    if (s == RealtimeState.closed && _state != CallState.closed && _state != CallState.idle) {
      await _teardown();
      _set(CallState.closed);
      _emit(_ended, const CallEnded('disconnected'));
      return;
    }
    if (s != RealtimeState.connected || !_wasConnected || _state != CallState.reconnecting || _resyncing) return;
    _resyncing = true;
    try {
      final fresh = await _signal.request('media.join');
      _set(CallState.joined);
      for (final t in [_sendT, _recvT]) {
        if (t != null && !t.closed) await _restartIce(t);
      }
      await _reconcile(((fresh['peers'] ?? const []) as List).cast<Map<String, dynamic>>());
    } catch (e) {
      // The server no longer has this person (they were away too long): the call is over for them.
      await _teardown();
      _set(CallState.closed);
      _emit(_ended, CallEnded(e is CallException && e.reason != null ? e.reason! : 'rejoin_failed'));
    } finally {
      _resyncing = false;
    }
  }

  Future<void> _teardown() async {
    _resyncTimer?.cancel();
    _resyncTimer = null;
    await _stateSub?.cancel();
    await _roomSub?.cancel();
    _stateSub = _roomSub = null;
    for (final t in _lapse.values) {
      t.cancel();
    }
    _lapse.clear();
    for (final p in _producers.values) {
      p.close();
    }
    _producers.clear();
    for (final c in _consumers.values) {
      c.consumer.close();
    }
    _consumers.clear();
    _sendT?.close();
    _recvT?.close();
    _sendT = _recvT = null;
    _peers.clear();
    _signal.disconnect();
  }
}
