// One WebRTC peer connection driven the way the mediasoup server expects: every track the phone sends is a section in an offer
// the phone makes and the "remote" answer is built from what the server said it will receive; every track it receives is a section
// in an offer built from what the server will send, answered by the engine.
//
// Derived from mediasoup-client's Chrome111 handler (ISC licence, Copyright (c) 2015, Iñaki Baz Castillo and contributors).
library;

import 'link.dart';
import 'ortc.dart';
import 'remote_sdp.dart';
import 'sdp.dart';

class SendResult {
  SendResult({required this.localId, required this.rtpParameters, required this.transceiver});
  final String localId;
  final Json rtpParameters;
  final LinkTransceiver transceiver;
}

class ReceiveItem {
  ReceiveItem({required this.trackId, required this.kind, required this.rtpParameters});
  final String trackId;
  final String kind;
  final Json rtpParameters;
}

class ReceiveResult {
  ReceiveResult({required this.localId, required this.track, required this.transceiver});
  final String localId;
  final MediaTrack track;
  final LinkTransceiver transceiver;
}

/// Native capabilities of this engine, read from an SDP offer it made.
Json localRtpCapabilities(Json sdp, [List<Json> extraHeaderExtensions = const []]) {
  final caps = extractRtpCapabilities(sdp);
  validateAndNormalizeRtpCapabilities(caps);
  addNackSupportForOpus(caps);
  for (final e in extraHeaderExtensions) {
    addHeaderExtensionSupport(caps, e);
  }
  return caps;
}

/// What an SDP says the engine can send or receive.
Json extractRtpCapabilities(Json sdp) {
  final codecs = <int, Json>{};
  final exts = <int, Json>{};
  for (final m in (sdp['media'] as List).cast<Json>()) {
    final kind = m['type'] as String;
    if (kind != 'audio' && kind != 'video') continue;
    for (final r in ((m['rtp'] ?? const []) as List).cast<Json>()) {
      final c = <String, dynamic>{
        'kind': kind,
        'mimeType': '$kind/${r['codec']}',
        'preferredPayloadType': r['payload'],
        'clockRate': r['rate'],
        if (r['encoding'] != null) 'channels': r['encoding'],
        'parameters': <String, dynamic>{},
        'rtcpFeedback': <dynamic>[],
      };
      codecs[r['payload'] as int] = c;
    }
    for (final f in ((m['fmtp'] ?? const []) as List).cast<Json>()) {
      final c = codecs[f['payload']];
      if (c == null) continue;
      final p = parseParams(f['config'] as String);
      if (p.containsKey('profile-level-id')) p['profile-level-id'] = '${p['profile-level-id']}';
      c['parameters'] = p;
    }
    for (final fb in ((m['rtcpFb'] ?? const []) as List).cast<Json>()) {
      final feedback = <String, dynamic>{'type': fb['type'], if (fb['subtype'] != null && fb['subtype'] != '') 'parameter': fb['subtype']};
      if (fb['payload'] != '*') {
        final c = codecs[fb['payload']];
        if (c == null) continue;
        (c['rtcpFeedback'] as List).add(feedback);
      } else {
        for (final c in codecs.values) {
          if (c['kind'] == kind && !isRtxCodec(c)) (c['rtcpFeedback'] as List).add(feedback);
        }
      }
    }
    for (final e in ((m['ext'] ?? const []) as List).cast<Json>()) {
      if (e['encrypt-uri'] != null) continue;
      exts[e['value'] as int] = {'kind': kind, 'uri': e['uri'], 'preferredId': e['value']};
    }
  }
  return {'codecs': codecs.values.toList(), 'headerExtensions': exts.values.toList()};
}

/// The DTLS role and fingerprint the engine put in its SDP.
Json extractDtlsParameters(Json sdp) {
  var setup = sdp['setup'];
  var fingerprint = sdp['fingerprint'];
  if (setup == null || fingerprint == null) {
    final m = (sdp['media'] as List).cast<Json>().where((m) => m['port'] != 0).firstOrNull;
    if (m != null) {
      setup ??= m['setup'];
      fingerprint ??= m['fingerprint'];
    }
  }
  if (setup == null) throw StateError('no a=setup found at SDP session or media level');
  if (fingerprint == null) throw StateError('no a=fingerprint found at SDP session or media level');
  return {
    'role': switch (setup) { 'active' => 'client', 'passive' => 'server', _ => 'auto' },
    'fingerprints': [
      {'algorithm': (fingerprint as Json)['type'], 'value': fingerprint['hash']},
    ],
  };
}

String getCname(Json offerMediaObject) {
  final line = ((offerMediaObject['ssrcs'] ?? const []) as List).cast<Json>().where((l) => l['attribute'] == 'cname').firstOrNull;
  return line == null ? '' : '${line['value']}';
}

/// One encoding per SSRC, with the RTX stream joined to the stream it repairs.
List<Json> getRtpEncodings(Json offerMediaObject) {
  final ssrcs = <int>{};
  for (final l in ((offerMediaObject['ssrcs'] ?? const []) as List).cast<Json>()) {
    if (l['id'] != null) ssrcs.add(l['id'] as int);
  }
  if (ssrcs.isEmpty) throw StateError('no a=ssrc lines found');
  final toRtx = <int, int?>{};
  for (final l in ((offerMediaObject['ssrcGroups'] ?? const []) as List).cast<Json>()) {
    if (l['semantics'] != 'FID') continue;
    final parts = (l['ssrcs'] as String).split(RegExp(r'\s+'));
    final ssrc = int.parse(parts[0]);
    final rtx = int.parse(parts[1]);
    if (ssrcs.contains(ssrc)) {
      ssrcs.remove(ssrc);
      ssrcs.remove(rtx);
      toRtx[ssrc] = rtx;
    }
  }
  for (final s in ssrcs) {
    toRtx[s] = null;
  }
  return [
    for (final e in toRtx.entries) {'ssrc': e.key, if (e.value != null && e.value != 0) 'rtx': {'ssrc': e.value}},
  ];
}

/// The Opus options the answer must repeat: stereo, as the sender said.
void applyCodecParameters(Json offerRtpParameters, Json answerMediaObject) {
  for (final codec in (offerRtpParameters['codecs'] as List).cast<Json>()) {
    final mt = (codec['mimeType'] as String).toLowerCase();
    if (mt != 'audio/opus') continue;
    final rtp = ((answerMediaObject['rtp'] ?? const []) as List).cast<Json>().where((r) => r['payload'] == codec['payloadType']).firstOrNull;
    if (rtp == null) continue;
    final fmtps = (answerMediaObject['fmtp'] ??= <dynamic>[] as dynamic) as List;
    var fmtp = fmtps.cast<Json>().where((f) => f['payload'] == codec['payloadType']).firstOrNull;
    if (fmtp == null) {
      fmtp = {'payload': codec['payloadType'], 'config': ''};
      fmtps.add(fmtp);
    }
    final params = parseParams(fmtp['config'] as String);
    final stereo = (codec['parameters'] as Json?)?['sprop-stereo'];
    if (stereo != null) params['stereo'] = (stereo is num ? stereo != 0 : '$stereo' != '0' && '$stereo' != '') ? 1 : 0;
    fmtp['config'] = [for (final e in params.entries) '${e.key}=${e.value}'].join(';');
  }
}

typedef ConnectDtls = Future<void> Function(Json dtlsParameters);

class Handler {
  Handler({
    required this.direction,
    required Json iceParameters,
    required List<dynamic> iceCandidates,
    required Json dtlsParameters,
    required this.link,
    required this.getSendExtendedRtpCapabilities,
    required this.onConnect,
  })  : _remote = RemoteSdp(iceParameters: iceParameters, iceCandidates: iceCandidates, dtlsParameters: dtlsParameters),
        _forcedLocalDtlsRole = (dtlsParameters['role'] != null && dtlsParameters['role'] != 'auto') ? (dtlsParameters['role'] == 'server' ? 'client' : 'server') : null;

  final String direction;
  final PeerLink link;
  final Json Function(Json nativeRtpCapabilities) getSendExtendedRtpCapabilities;
  final ConnectDtls onConnect;
  final RemoteSdp _remote;
  final String? _forcedLocalDtlsRole;
  final Map<String, LinkTransceiver> _byMid = {};
  bool _ready = false;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await link.close();
    } catch (_) {}
  }

  Future<void> _setupTransport(Json localSdp) async {
    final dtls = extractDtlsParameters(localSdp);
    final role = _forcedLocalDtlsRole ?? 'client';
    dtls['role'] = role;
    _remote.updateDtlsRole(role == 'client' ? 'server' : 'client');
    await onConnect(dtls);
    _ready = true;
  }

  Future<void> restartIce(Json iceParameters) async {
    _remote.updateIceParameters(iceParameters);
    if (!_ready) return;
    if (direction == 'send') {
      await link.setLocalDescription('offer', await link.createOffer(iceRestart: true));
      await link.setRemoteDescription('answer', _remote.getSdp());
    } else {
      await link.setRemoteDescription('offer', _remote.getSdp());
      await link.setLocalDescription('answer', await link.createAnswer());
    }
  }

  Future<List<Json>> getTransportStats() => link.getStats();

  /// Starts sending [track]. [kind] is `audio` or `video`; [streamId] groups a person's tracks.
  Future<SendResult> send({required MediaTrack track, required String streamId, int? maxBitrate, Json? codecOptions}) async {
    if (direction != 'send') throw StateError('not a sending transport');
    final idx = _remote.getNextMediaSectionIdx();
    final transceiver = await link.addSendTransceiver(track, streamId: streamId, maxBitrate: maxBitrate);
    final offer = await link.createOffer();
    var local = parseSdp(offer);
    if (local['extmapAllowMixed'] != null) _remote.setSessionExtmapAllowMixed();
    final native = localRtpCapabilities(local, [
      {'uri': 'http://www.webrtc.org/experiments/rtp-hdrext/abs-capture-time', 'kind': track.kind, 'direction': 'sendonly'},
    ]);
    final ext = getSendExtendedRtpCapabilities(native);
    final params = getSendingRtpParameters(track.kind, ext);
    params['codecs'] = reduceCodecs((params['codecs'] as List).cast<Json>());
    final remoteParams = getSendingRemoteRtpParameters(track.kind, ext);
    remoteParams['codecs'] = reduceCodecs((remoteParams['codecs'] as List).cast<Json>());
    if (!_ready) await _setupTransport(local);
    await link.setLocalDescription('offer', offer);
    local = parseSdp((await link.localSdp()) ?? offer);
    final media = (local['media'] as List).cast<Json>()[idx.idx];
    final localId = '${media['mid']}';
    params['mid'] = localId;
    (params['rtcp'] as Json)['cname'] = getCname(media);
    params['msid'] = '$streamId ${track.id}';
    params['encodings'] = getRtpEncodings(media);
    _remote.send(offerMediaObject: media, reuseMid: idx.reuseMid, offerRtpParameters: params, answerRtpParameters: remoteParams, codecOptions: codecOptions);
    await link.setRemoteDescription('answer', _remote.getSdp());
    _byMid[localId] = transceiver;
    return SendResult(localId: localId, rtpParameters: params, transceiver: transceiver);
  }

  Future<void> stopSending(String localId) async {
    if (_closed) return;
    final t = _byMid[localId];
    if (t == null) throw StateError('associated transceiver not found');
    await t.replaceTrack(null);
    final closed = _remote.closeMediaSection(localId);
    if (closed) {
      try {
        await t.stop();
      } catch (_) {}
    }
    await link.setLocalDescription('offer', await link.createOffer());
    await link.setRemoteDescription('answer', _remote.getSdp());
    _byMid.remove(localId);
  }

  Future<List<ReceiveResult>> receive(List<ReceiveItem> items) async {
    if (direction != 'recv') throw StateError('not a receiving transport');
    final localIds = <String, String>{};
    for (final it in items) {
      final localId = (it.rtpParameters['mid'] as String?) ?? '${_byMid.length}';
      localIds[it.trackId] = localId;
      final ms = msidParts(it.rtpParameters['msid'] as String?);
      _remote.receive(
        mid: localId,
        kind: it.kind,
        offerRtpParameters: it.rtpParameters,
        streamId: ms.streamId ?? (it.rtpParameters['rtcp'] as Json?)?['cname'] as String? ?? '-',
        trackId: it.trackId,
      );
    }
    await link.setRemoteDescription('offer', _remote.getSdp());
    final answer = await link.createAnswer();
    final local = parseSdp(answer);
    final fixed = _withOpusParameters(answer, local, items, localIds);
    if (!_ready) await _setupTransport(local);
    await link.setLocalDescription('answer', fixed);
    final out = <ReceiveResult>[];
    for (final it in items) {
      final localId = localIds[it.trackId]!;
      final t = await link.transceiverByMid(localId);
      if (t == null) throw StateError('new transceiver not found');
      _byMid[localId] = t;
      final track = t.receiverTrack;
      if (track == null) throw StateError('the received section has no track');
      out.add(ReceiveResult(localId: localId, track: track, transceiver: t));
    }
    return out;
  }

  /// The engine's answer with the Opus options the sender asked for. Only the lines that change are rewritten, so everything else
  /// the engine said is kept as it was.
  String _withOpusParameters(String answer, Json local, List<ReceiveItem> items, Map<String, String> localIds) {
    var text = answer;
    for (final it in items) {
      final m = (local['media'] as List).cast<Json>().where((m) => '${m['mid']}' == localIds[it.trackId]).firstOrNull;
      if (m == null) continue;
      final before = deepCopy<Json>(m);
      applyCodecParameters(it.rtpParameters, m);
      final oldF = ((before['fmtp'] ?? const []) as List).cast<Json>();
      for (final f in ((m['fmtp'] ?? const []) as List).cast<Json>()) {
        final old = oldF.where((o) => o['payload'] == f['payload']).firstOrNull;
        if (old != null && old['config'] == f['config']) continue;
        text = _setFmtp(text, '${m['mid']}', f['payload'] as int, f['config'] as String, replace: old != null);
      }
    }
    return text;
  }

  Future<void> stopReceiving(List<String> localIds) async {
    if (_closed) return;
    for (final id in localIds) {
      if (!_byMid.containsKey(id)) throw StateError('associated transceiver not found');
      _remote.closeMediaSection(id);
    }
    await link.setRemoteDescription('offer', _remote.getSdp());
    await link.setLocalDescription('answer', await link.createAnswer());
    for (final id in localIds) {
      _byMid.remove(id);
    }
  }

  Future<List<Json>> getReceiverStats(String localId) async {
    final t = _byMid[localId];
    if (t == null) throw StateError('associated transceiver not found');
    return t.getStats();
  }
}

/// Sets one `a=fmtp` line inside the media section with [mid], keeping every other line.
String _setFmtp(String sdp, String mid, int payload, String config, {required bool replace}) {
  final lines = sdp.split('\r\n');
  var start = -1, end = lines.length;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('m=')) {
      if (start >= 0) {
        end = i;
        break;
      }
    }
    if (lines[i] == 'a=mid:$mid') {
      // The section began at the nearest `m=` line above.
      for (var j = i; j >= 0; j--) {
        if (lines[j].startsWith('m=')) {
          start = j;
          break;
        }
      }
      for (var j = start + 1; j < lines.length; j++) {
        if (lines[j].startsWith('m=')) {
          end = j;
          break;
        }
      }
      break;
    }
  }
  if (start < 0) return sdp;
  final line = 'a=fmtp:$payload $config';
  for (var i = start; i < end; i++) {
    if (lines[i].startsWith('a=fmtp:$payload ')) {
      lines[i] = line;
      return lines.join('\r\n');
    }
  }
  // No line yet: it goes straight after the `a=rtpmap` of that payload.
  for (var i = start; i < end; i++) {
    if (lines[i].startsWith('a=rtpmap:$payload ')) {
      lines.insert(i + 1, line);
      return lines.join('\r\n');
    }
  }
  return sdp;
}
