// The mediasoup client's public pieces: a Device that knows what this phone can do, Transports that carry media, and the Producers
// and Consumers on them. Written for Zapiack against the mediasoup protocol, with no mediasoup package behind it.
//
// Derived from mediasoup-client (ISC licence, Copyright (c) 2015, Iñaki Baz Castillo and contributors).
library;

import 'dart:async';

import 'handler.dart';
import 'link.dart';
import 'ortc.dart';
import 'sdp.dart';

export 'link.dart' show LinkFactory, MediaTrack, PeerLink;
export 'ortc.dart' show Json;

/// What the phone and the router can both do.
class Device {
  Device(this.factory);

  final LinkFactory factory;
  Json? _router;
  Json? _recvCaps;

  bool get loaded => _recvCaps != null;

  /// What this phone can receive, to hand to the server when asking for a track.
  Json get rtpCapabilities {
    final c = _recvCaps;
    if (c == null) throw StateError('The device is not loaded.');
    return c;
  }

  /// Learns what the engine can do and matches it with the router's capabilities (from `media.join`).
  Future<void> load(Json routerRtpCapabilities) async {
    if (loaded) throw StateError('The device is already loaded.');
    final router = deepCopy(routerRtpCapabilities);
    validateAndNormalizeRtpCapabilities(router);
    final native = localRtpCapabilities(parseSdp(await factory.nativeOffer()));
    final ext = getExtendedRtpCapabilities(deepCopy(native), deepCopy(router));
    final recv = getRecvRtpCapabilities(ext);
    validateAndNormalizeRtpCapabilities(recv);
    _router = router;
    _recvCaps = recv;
  }

  /// Whether the router has a codec for [kind] that this phone can send.
  bool canProduce(String kind) {
    if (!loaded) throw StateError('The device is not loaded.');
    return ((_router!['codecs'] as List).cast<Json>()).any((c) => c['kind'] == kind);
  }

  Transport createSendTransport(TransportOptions o) => _transport('send', o);
  Transport createRecvTransport(TransportOptions o) => _transport('recv', o);

  Transport _transport(String direction, TransportOptions o) {
    if (!loaded) throw StateError('The device is not loaded.');
    return Transport._(this, direction, o);
  }
}

/// Everything the server said about a transport, plus where to connect through.
class TransportOptions {
  TransportOptions({
    required this.id,
    required this.iceParameters,
    required this.iceCandidates,
    required this.dtlsParameters,
    this.iceServers = const [],
    this.iceTransportPolicy = 'all',
  });
  final String id;
  final Json iceParameters;
  final List<dynamic> iceCandidates;
  final Json dtlsParameters;
  final List<Json> iceServers;
  final String iceTransportPolicy;
}

typedef ProduceCallback = Future<String> Function({required String kind, required Json rtpParameters, required Json appData});

class Transport {
  Transport._(this._device, this.direction, TransportOptions o)
      : id = o.id,
        _link = _device.factory.create(iceServers: o.iceServers, iceTransportPolicy: o.iceTransportPolicy) {
    _handler = Handler(
      direction: direction,
      iceParameters: deepCopy(o.iceParameters),
      iceCandidates: deepCopy(o.iceCandidates),
      dtlsParameters: deepCopy(o.dtlsParameters),
      link: _link,
      getSendExtendedRtpCapabilities: (native) => getExtendedRtpCapabilities(native, deepCopy(_device._router!)),
      onConnect: (dtls) async {
        final fn = onConnect;
        if (fn == null) throw StateError('onConnect is not set: the transport cannot be connected.');
        await fn(dtls);
      },
    );
    _link.onConnectionState = (s) {
      if (_closed) return;
      connectionState = s;
      onConnectionStateChange?.call(s);
    };
  }

  final Device _device;
  final String direction;
  final String id;
  final PeerLink _link;
  late final Handler _handler;
  bool _closed = false;
  Future<void> _queue = Future.value();
  final Map<String, Producer> _producers = {};
  final Map<String, Consumer> _consumers = {};

  /// `new`, `connecting`, `connected`, `disconnected`, `failed` or `closed`.
  String connectionState = 'new';
  bool get closed => _closed;

  /// Tell the server to connect this transport with these DTLS parameters. Called once, the first time anything uses it.
  Future<void> Function(Json dtlsParameters)? onConnect;

  /// Tell the server a track is being sent; it answers with the id it gave it. Only on a sending transport.
  ProduceCallback? onProduce;
  void Function(String state)? onConnectionStateChange;

  /// Runs one thing at a time on the connection: negotiation steps must not overlap.
  Future<T> _run<T>(Future<T> Function() task) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await task());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// Sends [track]. [appData] travels to the server with it (the app says what the track is: microphone, camera or screen).
  Future<Producer> produce({required MediaTrack track, Json appData = const {}, int? maxBitrate, Json? codecOptions, String streamId = 'zapiack'}) {
    if (_closed) throw StateError('The transport is closed.');
    if (direction != 'send') throw StateError('Not a sending transport.');
    final onProduce = this.onProduce;
    if (onProduce == null) throw StateError('onProduce is not set.');
    if (track.kind != 'audio' && track.kind != 'video') throw ArgumentError('The track must be audio or video.');
    if (!_device.canProduce(track.kind)) throw StateError('Cannot send ${track.kind}: the server has no codec for it.');
    return _run(() async {
      final r = await _handler.send(track: track, streamId: streamId, maxBitrate: maxBitrate, codecOptions: codecOptions);
      try {
        final id = await onProduce(kind: track.kind, rtpParameters: r.rtpParameters, appData: deepCopy(appData));
        final p = Producer._(this, id, r.localId, track, appData);
        _producers[id] = p;
        return p;
      } catch (e) {
        // The server refused it: take the section back out so the connection is as it was.
        try {
          await _handler.stopSending(r.localId);
        } catch (_) {}
        rethrow;
      }
    });
  }

  /// Receives a track the server describes: the answer to `media.consume`.
  Future<Consumer> consume({required String id, required String producerId, required String kind, required Json rtpParameters, Json appData = const {}}) {
    if (_closed) throw StateError('The transport is closed.');
    if (direction != 'recv') throw StateError('Not a receiving transport.');
    final params = deepCopy(rtpParameters);
    if (!canReceive(params, _device.rtpCapabilities)) throw StateError('Cannot receive this track: the codec is not one this phone can take.');
    return _run(() async {
      final out = await _handler.receive([ReceiveItem(trackId: id, kind: kind, rtpParameters: params)]);
      final c = Consumer._(this, id, out.single.localId, producerId, kind, out.single.track, appData);
      _consumers[id] = c;
      return c;
    });
  }

  /// Negotiates again with fresh ICE parameters from the server: the way back after the network changed.
  Future<void> restartIce(Json iceParameters) {
    if (_closed) throw StateError('The transport is closed.');
    return _run(() => _handler.restartIce(deepCopy(iceParameters)));
  }

  Future<List<Json>> getStats() => _handler.getTransportStats();

  void close() {
    if (_closed) return;
    _closed = true;
    connectionState = 'closed';
    for (final p in _producers.values.toList()) {
      p._transportClosed();
    }
    for (final c in _consumers.values.toList()) {
      c._transportClosed();
    }
    _producers.clear();
    _consumers.clear();
    unawaited(_handler.close());
  }
}

class Producer {
  Producer._(this._t, this.id, this._localId, this.track, this.appData);

  final Transport _t;
  final String _localId;
  final String id;
  final MediaTrack track;
  final Json appData;
  bool _closed = false;
  bool _paused = false;

  bool get closed => _closed;
  bool get paused => _paused;
  String get kind => track.kind;

  /// Called when the transport it was on has closed.
  void Function()? onTransportClose;

  /// Sends nothing while paused (silence, or a frozen picture), without renegotiating.
  void pause() {
    if (_closed) return;
    _paused = true;
    track.enabled = false;
  }

  void resume() {
    if (_closed) return;
    _paused = false;
    track.enabled = true;
  }

  /// Stops sending and releases the track and the device behind it.
  void close() {
    if (_closed) return;
    _closed = true;
    _t._producers.remove(id);
    unawaited(track.stop());
    if (!_t.closed) unawaited(_t._run(() => _t._handler.stopSending(_localId)).catchError((_) {}));
  }

  void _transportClosed() {
    if (_closed) return;
    _closed = true;
    unawaited(track.stop());
    onTransportClose?.call();
  }
}

class Consumer {
  Consumer._(this._t, this.id, this._localId, this.producerId, this.kind, this.track, this.appData);

  final Transport _t;
  final String _localId;
  final String id;
  final String producerId;
  final String kind;
  final MediaTrack track;
  final Json appData;
  bool _closed = false;

  bool get closed => _closed;
  void Function()? onTransportClose;

  /// Per-stream numbers from the engine: the report entries for this track.
  Future<List<Json>> getStats() => _t._handler.getReceiverStats(_localId);

  void close() {
    if (_closed) return;
    _closed = true;
    _t._consumers.remove(id);
    if (!_t.closed) unawaited(_t._run(() => _t._handler.stopReceiving([_localId])).catchError((_) {}));
  }

  void _transportClosed() {
    if (_closed) return;
    _closed = true;
    onTransportClose?.call();
  }
}
