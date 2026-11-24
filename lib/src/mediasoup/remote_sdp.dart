// The server's side of the conversation, written as SDP. A phone's WebRTC engine only knows SDP, so everything the mediasoup
// server says about a transport (ICE, DTLS) and about each track (codecs, SSRCs) is turned into the SDP the engine would have
// received from a real peer: an answer for each track the phone sends, an offer for each it receives.
//
// Derived from mediasoup-client (ISC licence, Copyright (c) 2015, Iñaki Baz Castillo and contributors).
library;

import 'ortc.dart';
import 'sdp.dart';

class MediaSection {
  MediaSection(this.object, {this.isOffer = false});
  final Json object;

  /// A section that describes what the server sends is an offer, and an offer always leaves the DTLS role open (`actpass`).
  final bool isOffer;

  String get mid => '${object['mid']}';
  bool get closed => object['port'] == 0;

  void setIceParameters(Json ice) {
    object['iceUfrag'] = ice['usernameFragment'];
    object['icePwd'] = ice['password'];
  }

  void setDtlsRole(String role) {
    object['setup'] = isOffer ? 'actpass' : switch (role) { 'client' => 'active', 'server' => 'passive', _ => 'actpass' };
  }

  void pause() => object['direction'] = 'inactive';

  void disable() {
    pause();
    for (final k in const ['ext', 'ssrcs', 'ssrcGroups', 'simulcast', 'simulcast_03', 'rids', 'extmapAllowMixed']) {
      object.remove(k);
    }
  }

  void close() {
    disable();
    object['port'] = 0;
  }

  /// The ICE and DTLS part every section starts with.
  static Json base(Json? ice, List<dynamic>? candidates, Json? dtls, {bool offer = false}) {
    final o = <String, dynamic>{'type': '', 'port': 0, 'protocol': '', 'payloads': '', 'rtp': <dynamic>[], 'fmtp': <dynamic>[]};
    final s = MediaSection(o, isOffer: offer);
    if (ice != null) s.setIceParameters(ice);
    if (candidates != null) {
      o['candidates'] = <dynamic>[
        for (final c in candidates.cast<Json>())
          {
            'foundation': c['foundation'],
            'component': 1,
            'ip': c['address'] ?? c['ip'],
            'port': c['port'],
            'priority': c['priority'],
            'transport': c['protocol'],
            'type': c['type'],
            if (c['tcpType'] != null && c['tcpType'] != '') 'tcptype': c['tcpType'],
          },
      ];
      o['endOfCandidates'] = 'end-of-candidates';
      o['iceOptions'] = 'renomination';
    }
    if (dtls != null && dtls['role'] != null) s.setDtlsRole(dtls['role'] as String);
    return o;
  }
}

String _config(Json params) => [for (final e in params.entries) '${e.key}=${e.value}'].join(';');

/// The answer to a track the phone sends: the server saying what it will receive.
MediaSection answerMediaSection({
  required Json? iceParameters,
  required List<dynamic>? iceCandidates,
  required Json? dtlsParameters,
  required Json offerMediaObject,
  required Json offerRtpParameters,
  required Json answerRtpParameters,
  Json? codecOptions,
}) {
  final o = MediaSection.base(iceParameters, iceCandidates, dtlsParameters);
  o['mid'] = '${offerMediaObject['mid']}';
  o['type'] = offerMediaObject['type'];
  o['protocol'] = offerMediaObject['protocol'];
  o['connection'] = {'ip': '127.0.0.1', 'version': 4};
  o['port'] = 7;
  o['direction'] = 'recvonly';
  final rtp = <Json>[], rtcpFb = <Json>[], fmtp = <Json>[];
  o['rtp'] = rtp;
  o['rtcpFb'] = rtcpFb;
  o['fmtp'] = fmtp;
  final answerCodecs = (answerRtpParameters['codecs'] as List).cast<Json>();
  for (final codec in answerCodecs) {
    final r = <String, dynamic>{'payload': codec['payloadType'], 'codec': _codecName(codec), 'rate': codec['clockRate']};
    if (codec['channels'] != null && (codec['channels'] as num) > 1) r['encoding'] = codec['channels'];
    rtp.add(r);
    final codecParameters = deepCopy<Json>((codec['parameters'] ?? <String, dynamic>{}) as Json);
    var feedback = deepCopy<List<dynamic>>((codec['rtcpFeedback'] ?? <dynamic>[]) as List).cast<Json>();
    if (codecOptions != null) {
      final offerCodec = (offerRtpParameters['codecs'] as List).cast<Json>().firstWhere((c) => c['payloadType'] == codec['payloadType']);
      switch ((codec['mimeType'] as String).toLowerCase()) {
        case 'audio/opus' || 'audio/multiopus':
          final op = offerCodec['parameters'] as Json;
          if (codecOptions['opusStereo'] != null) {
            op['sprop-stereo'] = codecOptions['opusStereo'] == true ? 1 : 0;
            codecParameters['stereo'] = codecOptions['opusStereo'] == true ? 1 : 0;
          }
          if (codecOptions['opusFec'] != null) {
            op['useinbandfec'] = codecOptions['opusFec'] == true ? 1 : 0;
            codecParameters['useinbandfec'] = codecOptions['opusFec'] == true ? 1 : 0;
          }
          if (codecOptions['opusDtx'] != null) {
            op['usedtx'] = codecOptions['opusDtx'] == true ? 1 : 0;
            codecParameters['usedtx'] = codecOptions['opusDtx'] == true ? 1 : 0;
          }
          if (codecOptions['opusMaxPlaybackRate'] != null) codecParameters['maxplaybackrate'] = codecOptions['opusMaxPlaybackRate'];
          if (codecOptions['opusMaxAverageBitrate'] != null) codecParameters['maxaveragebitrate'] = codecOptions['opusMaxAverageBitrate'];
          if (codecOptions['opusPtime'] != null) {
            op['ptime'] = codecOptions['opusPtime'];
            codecParameters['ptime'] = codecOptions['opusPtime'];
          }
          if (codecOptions['opusNack'] != true) {
            offerCodec['rtcpFeedback'] = [for (final fb in (offerCodec['rtcpFeedback'] as List).cast<Json>()) if (fb['type'] != 'nack' || !_falsy(fb['parameter'])) fb];
            feedback = [for (final fb in feedback) if (fb['type'] != 'nack' || !_falsy(fb['parameter'])) fb];
          }
        case 'video/vp8' || 'video/vp9' || 'video/h264' || 'video/h265' || 'video/av1':
          if (codecOptions['videoGoogleStartBitrate'] != null) codecParameters['x-google-start-bitrate'] = codecOptions['videoGoogleStartBitrate'];
          if (codecOptions['videoGoogleMaxBitrate'] != null) codecParameters['x-google-max-bitrate'] = codecOptions['videoGoogleMaxBitrate'];
          if (codecOptions['videoGoogleMinBitrate'] != null) codecParameters['x-google-min-bitrate'] = codecOptions['videoGoogleMinBitrate'];
      }
    }
    final config = _config(codecParameters);
    if (config.isNotEmpty) fmtp.add({'payload': codec['payloadType'], 'config': config});
    for (final fb in feedback) {
      rtcpFb.add({'payload': codec['payloadType'], 'type': fb['type'], 'subtype': fb['parameter']});
    }
  }
  o['payloads'] = answerCodecs.map((c) => c['payloadType']).join(' ');
  final ext = <Json>[];
  o['ext'] = ext;
  for (final e in (answerRtpParameters['headerExtensions'] as List).cast<Json>()) {
    final found = ((offerMediaObject['ext'] ?? const []) as List).cast<Json>().any((l) => l['uri'] == e['uri']);
    if (found) ext.add({'uri': e['uri'], 'value': e['id']});
  }
  if (offerMediaObject['extmapAllowMixed'] == 'extmap-allow-mixed') o['extmapAllowMixed'] = 'extmap-allow-mixed';
  o['rtcpMux'] = 'rtcp-mux';
  o['rtcpRsize'] = 'rtcp-rsize';
  return MediaSection(o);
}

/// The offer for a track the phone receives: the server describing what it will send.
MediaSection offerMediaSection({
  required Json? iceParameters,
  required List<dynamic>? iceCandidates,
  required Json? dtlsParameters,
  required String mid,
  required String kind,
  required Json offerRtpParameters,
  required String streamId,
  required String trackId,
}) {
  final o = MediaSection.base(iceParameters, iceCandidates, dtlsParameters, offer: true);
  o['mid'] = mid;
  o['type'] = kind;
  o['connection'] = {'ip': '127.0.0.1', 'version': 4};
  o['protocol'] = 'UDP/TLS/RTP/SAVPF';
  o['port'] = 7;
  o['extmapAllowMixed'] = 'extmap-allow-mixed';
  o['direction'] = 'sendonly';
  final rtp = <Json>[], rtcpFb = <Json>[], fmtp = <Json>[];
  o['rtp'] = rtp;
  o['rtcpFb'] = rtcpFb;
  o['fmtp'] = fmtp;
  o['msid'] = [
    {'id': streamId, 'appdata': trackId},
  ];
  final codecs = (offerRtpParameters['codecs'] as List).cast<Json>();
  for (final codec in codecs) {
    final r = <String, dynamic>{'payload': codec['payloadType'], 'codec': _codecName(codec), 'rate': codec['clockRate']};
    if (codec['channels'] != null && (codec['channels'] as num) > 1) r['encoding'] = codec['channels'];
    rtp.add(r);
    final config = _config((codec['parameters'] ?? <String, dynamic>{}) as Json);
    if (config.isNotEmpty) fmtp.add({'payload': codec['payloadType'], 'config': config});
    for (final fb in ((codec['rtcpFeedback'] ?? const []) as List).cast<Json>()) {
      rtcpFb.add({'payload': codec['payloadType'], 'type': fb['type'], 'subtype': fb['parameter']});
    }
  }
  o['payloads'] = codecs.map((c) => c['payloadType']).join(' ');
  o['ext'] = [
    for (final e in (offerRtpParameters['headerExtensions'] as List).cast<Json>()) {'uri': e['uri'], 'value': e['id']},
  ];
  o['rtcpMux'] = 'rtcp-mux';
  o['rtcpRsize'] = 'rtcp-rsize';
  final encodings = (offerRtpParameters['encodings'] as List).cast<Json>();
  final enc = encodings.isEmpty ? <String, dynamic>{} : encodings[0];
  final ssrc = enc['ssrc'];
  final rtxSsrc = (enc['rtx'] as Json?)?['ssrc'];
  final cname = (offerRtpParameters['rtcp'] as Json?)?['cname'];
  final ssrcs = <Json>[], groups = <Json>[];
  o['ssrcs'] = ssrcs;
  o['ssrcGroups'] = groups;
  if (ssrc != null && cname != null && cname != '') ssrcs.add({'id': ssrc, 'attribute': 'cname', 'value': cname});
  if (rtxSsrc != null) {
    if (cname != null && cname != '') ssrcs.add({'id': rtxSsrc, 'attribute': 'cname', 'value': cname});
    if (ssrc != null) groups.add({'semantics': 'FID', 'ssrcs': '$ssrc $rtxSsrc'});
  }
  return MediaSection(o, isOffer: true);
}

bool _falsy(Object? v) => v == null || v == '' || v == false || v == 0;

String _codecName(Json codec) {
  final m = RegExp(r'^(audio|video)/(.+)', caseSensitive: false).firstMatch(codec['mimeType'] as String);
  return m!.group(2)!;
}

/// The whole remote SDP for one transport. Sections are only ever added, paused, resumed or closed (a closed one is reused by the
/// next track), so the `m=` lines keep their order, as WebRTC requires.
class RemoteSdp {
  RemoteSdp({required Json iceParameters, required List<dynamic> iceCandidates, required Json dtlsParameters})
      : _ice = iceParameters,
        _candidates = iceCandidates,
        _dtls = dtlsParameters {
    final fps = (dtlsParameters['fingerprints'] as List).cast<Json>();
    _sdp = <String, dynamic>{
      'version': 0,
      'origin': {'address': '0.0.0.0', 'ipVer': 4, 'netType': 'IN', 'sessionId': '10000', 'sessionVersion': 0, 'username': 'mediasoup-client'},
      'name': '-',
      'timing': {'start': 0, 'stop': 0},
      'media': <dynamic>[],
      'iceOptions': 'ice2',
      if (iceParameters['iceLite'] == true) 'icelite': 'ice-lite',
      'fingerprint': {'type': fps.last['algorithm'], 'hash': fps.last['value']},
      'groups': [
        {'type': 'BUNDLE', 'mids': ''},
      ],
    };
  }

  Json _ice;
  final List<dynamic> _candidates;
  final Json _dtls;
  late final Json _sdp;
  final List<MediaSection> _sections = [];
  final Map<String, int> _midToIndex = {};
  String? _firstMid;

  void updateIceParameters(Json ice) {
    _ice = ice;
    if (ice['iceLite'] == true) {
      _sdp['icelite'] = 'ice-lite';
    } else {
      _sdp.remove('icelite');
    }
    for (final s in _sections) {
      s.setIceParameters(ice);
    }
  }

  void updateDtlsRole(String role) {
    _dtls['role'] = role;
    for (final s in _sections) {
      s.setDtlsRole(role);
    }
  }

  void setSessionExtmapAllowMixed() => _sdp['extmapAllowMixed'] = 'extmap-allow-mixed';

  /// Where the next sent track goes: in a closed section's place if there is one.
  ({int idx, String? reuseMid}) getNextMediaSectionIdx() {
    for (var i = 0; i < _sections.length; i++) {
      if (_sections[i].closed) return (idx: i, reuseMid: _sections[i].mid);
    }
    return (idx: _sections.length, reuseMid: null);
  }

  void send({required Json offerMediaObject, String? reuseMid, required Json offerRtpParameters, required Json answerRtpParameters, Json? codecOptions}) {
    final s = answerMediaSection(
      iceParameters: _ice,
      iceCandidates: _candidates,
      dtlsParameters: _dtls,
      offerMediaObject: offerMediaObject,
      offerRtpParameters: offerRtpParameters,
      answerRtpParameters: answerRtpParameters,
      codecOptions: codecOptions,
    );
    final o = s.object;
    // The dependency descriptor only works with codecs that carry it. This server offers neither, so it is never advertised.
    final hasDd = (o['rtp'] as List).cast<Json>().any((r) => const ['av1', 'h264'].contains((r['codec'] as String).toLowerCase()));
    if (!hasDd) {
      o['ext'] = [for (final e in (o['ext'] as List).cast<Json>()) if (e['uri'] != 'https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension') e];
    }
    if (reuseMid != null) {
      _replace(s, reuseMid);
    } else if (!_midToIndex.containsKey(s.mid)) {
      _add(s);
    } else {
      _replace(s);
    }
  }

  void receive({required String mid, required String kind, required Json offerRtpParameters, required String streamId, required String trackId}) {
    setSessionExtmapAllowMixed();
    final s = offerMediaSection(
      iceParameters: _ice,
      iceCandidates: _candidates,
      dtlsParameters: _dtls,
      mid: mid,
      kind: kind,
      offerRtpParameters: offerRtpParameters,
      streamId: streamId,
      trackId: trackId,
    );
    final old = _sections.where((m) => m.closed).firstOrNull;
    if (old != null) {
      _replace(s, old.mid);
    } else {
      _add(s);
    }
  }

  MediaSection _find(String mid) {
    final i = _midToIndex[mid];
    if (i == null) throw StateError("no media section found with mid '$mid'");
    return _sections[i];
  }

  void pauseMediaSection(String mid) => _find(mid).pause();
  void resumeSendingMediaSection(String mid) => _find(mid).object['direction'] = 'recvonly';
  void resumeReceivingMediaSection(String mid) => _find(mid).object['direction'] = 'sendonly';
  void disableMediaSection(String mid) => _find(mid).disable();

  /// Closes a section. The first one cannot go (the bundle hangs on it), so it is disabled instead: false then.
  bool closeMediaSection(String mid) {
    final s = _find(mid);
    if (mid == _firstMid) {
      s.disable();
      return false;
    }
    s.close();
    _bundleMids();
    return true;
  }

  String getSdp() {
    (_sdp['origin'] as Json)['sessionVersion'] = ((_sdp['origin'] as Json)['sessionVersion'] as int) + 1;
    return writeSdp(_sdp);
  }

  void _add(MediaSection s) {
    _firstMid ??= s.mid;
    _sections.add(s);
    _midToIndex[s.mid] = _sections.length - 1;
    (_sdp['media'] as List).add(s.object);
    _bundleMids();
  }

  void _replace(MediaSection s, [String? reuseMid]) {
    if (reuseMid != null) {
      final i = _midToIndex[reuseMid];
      if (i == null) throw StateError("no media section found for reuseMid '$reuseMid'");
      final old = _sections[i];
      _sections[i] = s;
      _midToIndex.remove(old.mid);
      _midToIndex[s.mid] = i;
      (_sdp['media'] as List)[i] = s.object;
      _bundleMids();
    } else {
      final i = _midToIndex[s.mid];
      if (i == null) throw StateError("no media section found with mid '${s.mid}'");
      _sections[i] = s;
      (_sdp['media'] as List)[i] = s.object;
    }
  }

  void _bundleMids() {
    ((_sdp['groups'] as List)[0] as Json)['mids'] = _sections.where((s) => !s.closed).map((s) => s.mid).join(' ');
  }
}
