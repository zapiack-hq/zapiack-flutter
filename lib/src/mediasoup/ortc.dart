// What the phone can send and receive, matched against what the server's router offers, and the RTP parameters that follow from it.
// This is the part of the mediasoup protocol that decides which codec and which header extensions two sides will speak, so it
// follows the JavaScript client exactly. Everything is plain JSON-shaped maps, the same ones the server sends and takes back.
//
// Differences, on purpose: no simulcast or SVC (a call sends one encoding), no data channels, and H.264 is matched on its profile
// and packetisation mode only. The server offers Opus and VP8.
//
// Derived from mediasoup-client (ISC licence, Copyright (c) 2015, Iñaki Baz Castillo and contributors).
library;

typedef Json = Map<String, dynamic>;

Json _clone(Json j) => _deep(j) as Json;
Object? _deep(Object? v) {
  if (v is Map) return <String, dynamic>{for (final e in v.entries) e.key as String: _deep(e.value)};
  if (v is List) return [for (final x in v) _deep(x)];
  return v;
}

/// A copy of any JSON value. The negotiation edits what it is given, so callers hand it copies.
T deepCopy<T>(T v) => _deep(v as Object?) as T;

bool _falsy(Object? v) => v == null || v == '' || v == false || v == 0;

final _mime = RegExp(r'^(audio|video)/(.+)', caseSensitive: false);

/// Fills in what the capabilities leave out, as the JavaScript client does, and throws on what cannot be used.
void validateAndNormalizeRtpCapabilities(Json caps) {
  caps['codecs'] ??= <dynamic>[];
  for (final c in (caps['codecs'] as List).cast<Json>()) {
    final m = _mime.firstMatch((c['mimeType'] ?? '') as String);
    if (m == null) throw ArgumentError('invalid codec.mimeType');
    c['kind'] = m.group(1)!.toLowerCase();
    if (c['preferredPayloadType'] is! num) throw ArgumentError('missing codec.preferredPayloadType');
    if (c['clockRate'] is! num) throw ArgumentError('missing codec.clockRate');
    _normalizeCodec(c, c['kind'] == 'audio');
  }
  caps['headerExtensions'] ??= <dynamic>[];
  for (final e in (caps['headerExtensions'] as List).cast<Json>()) {
    if (e['kind'] != 'audio' && e['kind'] != 'video') throw ArgumentError('invalid ext.kind');
    if (_falsy(e['uri'])) throw ArgumentError('missing ext.uri');
    if (e['preferredId'] is! num) throw ArgumentError('missing ext.preferredId');
    if (_falsy(e['preferredEncrypt'])) e['preferredEncrypt'] = false;
    if (_falsy(e['direction'])) e['direction'] = 'sendrecv';
  }
}

void _normalizeCodec(Json c, bool audio) {
  if (audio) {
    if (c['channels'] is! num) c['channels'] = 1;
  } else {
    c.remove('channels');
  }
  if (c['parameters'] is! Map) c['parameters'] = <String, dynamic>{};
  final p = c['parameters'] as Json;
  for (final k in p.keys.toList()) {
    p[k] ??= '';
    if (p[k] is! String && p[k] is! num) throw ArgumentError('invalid codec parameter [key:$k]');
    if (k == 'apt' && p[k] is! num) throw ArgumentError('invalid codec apt parameter');
  }
  if (c['rtcpFeedback'] is! List) c['rtcpFeedback'] = <dynamic>[];
  for (final fb in (c['rtcpFeedback'] as List).cast<Json>()) {
    if (_falsy(fb['type'])) throw ArgumentError('missing fb.type');
    if (fb['parameter'] is! String || fb['parameter'] == '') fb['parameter'] = '';
  }
}

/// A codec in RTP parameters (payloadType, not preferredPayloadType): the same fill-in.
void validateAndNormalizeRtpParameters(Json params) {
  if (params['codecs'] is! List) throw ArgumentError('missing params.codecs');
  for (final c in (params['codecs'] as List).cast<Json>()) {
    final m = _mime.firstMatch((c['mimeType'] ?? '') as String);
    if (m == null) throw ArgumentError('invalid codec.mimeType');
    if (c['payloadType'] is! num) throw ArgumentError('missing codec.payloadType');
    if (c['clockRate'] is! num) throw ArgumentError('missing codec.clockRate');
    _normalizeCodec(c, m.group(1)!.toLowerCase() == 'audio');
  }
  params['headerExtensions'] ??= <dynamic>[];
  for (final e in (params['headerExtensions'] as List).cast<Json>()) {
    if (_falsy(e['uri'])) throw ArgumentError('missing ext.uri');
    if (e['id'] is! num) throw ArgumentError('missing ext.id');
    if (_falsy(e['encrypt'])) e['encrypt'] = false;
    if (e['parameters'] is! Map) e['parameters'] = <String, dynamic>{};
  }
  params['encodings'] ??= <dynamic>[];
  for (final e in (params['encodings'] as List).cast<Json>()) {
    if (e['dtx'] is! bool || e['dtx'] == false) e['dtx'] = false;
  }
  params['rtcp'] ??= <String, dynamic>{};
  final rtcp = params['rtcp'] as Json;
  if (rtcp['reducedSize'] is! bool || rtcp['reducedSize'] == false) rtcp['reducedSize'] = true;
}

bool isRtxCodec(Json? c) => c != null && RegExp(r'.+/rtx$', caseSensitive: false).hasMatch(c['mimeType'] as String);

int _level(Object? profileLevelId) {
  final s = profileLevelId?.toString() ?? '';
  return s.length == 6 ? int.tryParse(s.substring(4), radix: 16) ?? 0 : 0;
}

bool _matchCodecs(Json a, Json b, {bool strict = false, bool modify = false}) {
  final am = (a['mimeType'] as String).toLowerCase();
  if (am != (b['mimeType'] as String).toLowerCase()) return false;
  if (a['clockRate'] != b['clockRate']) return false;
  if (a['channels'] != b['channels']) return false;
  final ap = (a['parameters'] ?? <String, dynamic>{}) as Json;
  final bp = (b['parameters'] ?? <String, dynamic>{}) as Json;
  switch (am) {
    case 'video/h264':
      if (strict) {
        if ((ap['packetization-mode'] ?? 0) != (bp['packetization-mode'] ?? 0)) return false;
        final pa = ap['profile-level-id']?.toString(), pb = bp['profile-level-id']?.toString();
        if (pa != null && pb != null) {
          if (pa.length != 6 || pb.length != 6 || pa.substring(0, 4).toLowerCase() != pb.substring(0, 4).toLowerCase()) return false;
          if (modify) {
            final lvl = (_level(pa) < _level(pb) ? _level(pa) : _level(pb)).toRadixString(16).padLeft(2, '0');
            final id = '${pa.substring(0, 4)}$lvl';
            ap['profile-level-id'] = id;
            bp['profile-level-id'] = id;
          }
        }
      }
    case 'video/vp9':
      if (strict && (ap['profile-id'] ?? 0) != (bp['profile-id'] ?? 0)) return false;
  }
  return true;
}

bool _matchHeaderExtensions(Json a, Json b) {
  if (a['kind'] != null && b['kind'] != null && a['kind'] != b['kind']) return false;
  return a['uri'] == b['uri'];
}

List<dynamic> _reduceRtcpFeedback(Json a, Json b) {
  final out = <dynamic>[];
  for (final afb in ((a['rtcpFeedback'] ?? const []) as List).cast<Json>()) {
    for (final bfb in ((b['rtcpFeedback'] ?? const []) as List).cast<Json>()) {
      if (bfb['type'] == afb['type'] && (bfb['parameter'] == afb['parameter'] || (_falsy(bfb['parameter']) && _falsy(afb['parameter'])))) {
        out.add(bfb);
        break;
      }
    }
  }
  return out;
}

Json _noNulls(Json j) => {for (final e in j.entries) if (e.value != null) e.key: e.value};

/// The codecs and header extensions both sides share, with the payload types each side uses for them. [local] is this phone,
/// [remote] is the router; the router's order of preference wins.
Json getExtendedRtpCapabilities(Json local, Json remote, {bool preferLocalCodecsOrder = false}) {
  final codecs = <Json>[];
  final headerExtensions = <Json>[];
  final localCodecs = (local['codecs'] as List? ?? const []).cast<Json>();
  final remoteCodecs = (remote['codecs'] as List? ?? const []).cast<Json>();

  Json extended(Json l, Json r) => _noNulls({
        'kind': l['kind'],
        'mimeType': l['mimeType'],
        'clockRate': l['clockRate'],
        'channels': l['channels'],
        'localPayloadType': l['preferredPayloadType'],
        'remotePayloadType': r['preferredPayloadType'],
        'localParameters': l['parameters'] ?? <String, dynamic>{},
        'remoteParameters': r['parameters'] ?? <String, dynamic>{},
        'rtcpFeedback': _reduceRtcpFeedback(l, r),
      });

  if (preferLocalCodecsOrder) {
    for (final l in localCodecs) {
      if (isRtxCodec(l)) continue;
      final r = remoteCodecs.where((x) => _matchCodecs(x, l, strict: true, modify: true)).firstOrNull;
      if (r != null) codecs.add(extended(l, r));
    }
  } else {
    for (final r in remoteCodecs) {
      if (isRtxCodec(r)) continue;
      final l = localCodecs.where((x) => _matchCodecs(x, r, strict: true, modify: true)).firstOrNull;
      if (l != null) codecs.add(extended(l, r));
    }
  }

  for (final c in codecs) {
    final lrtx = localCodecs.where((x) => isRtxCodec(x) && (x['parameters'] as Json?)?['apt'] == c['localPayloadType']).firstOrNull;
    final rrtx = remoteCodecs.where((x) => isRtxCodec(x) && (x['parameters'] as Json?)?['apt'] == c['remotePayloadType']).firstOrNull;
    if (lrtx != null && rrtx != null) {
      c['localRtxPayloadType'] = lrtx['preferredPayloadType'];
      c['remoteRtxPayloadType'] = rrtx['preferredPayloadType'];
    }
  }

  for (final re in (remote['headerExtensions'] as List? ?? const []).cast<Json>()) {
    final le = (local['headerExtensions'] as List? ?? const []).cast<Json>().where((x) => _matchHeaderExtensions(x, re)).firstOrNull;
    if (le == null) continue;
    final direction = switch (re['direction']) {
      'sendrecv' => 'sendrecv',
      'recvonly' => 'sendonly',
      'sendonly' => 'recvonly',
      'inactive' => 'inactive',
      _ => 'sendrecv',
    };
    headerExtensions.add(_noNulls({
      'kind': re['kind'],
      'uri': re['uri'],
      'sendId': le['preferredId'],
      'recvId': re['preferredId'],
      'encrypt': le['preferredEncrypt'] ?? false,
      'direction': direction,
    }));
  }
  return {'codecs': codecs, 'headerExtensions': headerExtensions};
}

/// What this phone tells the server it can receive: the shared codecs, under the payload types the router uses.
Json getRecvRtpCapabilities(Json ext) {
  final codecs = <Json>[];
  final headerExtensions = <Json>[];
  for (final c in (ext['codecs'] as List).cast<Json>()) {
    codecs.add(_noNulls({
      'kind': c['kind'],
      'mimeType': c['mimeType'],
      'preferredPayloadType': c['remotePayloadType'],
      'clockRate': c['clockRate'],
      'channels': c['channels'],
      'parameters': c['localParameters'],
      'rtcpFeedback': c['rtcpFeedback'],
    }));
    if (c['remoteRtxPayloadType'] == null || c['remoteRtxPayloadType'] == 0) continue;
    codecs.add({
      'kind': c['kind'],
      'mimeType': '${c['kind']}/rtx',
      'preferredPayloadType': c['remoteRtxPayloadType'],
      'clockRate': c['clockRate'],
      'parameters': {'apt': c['remotePayloadType']},
      'rtcpFeedback': <dynamic>[],
    });
  }
  for (final e in (ext['headerExtensions'] as List).cast<Json>()) {
    if (e['direction'] != 'sendrecv' && e['direction'] != 'recvonly') continue;
    headerExtensions.add({
      'kind': e['kind'],
      'uri': e['uri'],
      'preferredId': e['recvId'],
      'preferredEncrypt': e['encrypt'] ?? false,
      'direction': e['direction'],
    });
  }
  return {'codecs': codecs, 'headerExtensions': headerExtensions};
}

Json _rtxOf(Json c) => {
      'mimeType': '${c['kind']}/rtx',
      'payloadType': c['localRtxPayloadType'],
      'clockRate': c['clockRate'],
      'parameters': {'apt': c['localPayloadType']},
      'rtcpFeedback': <dynamic>[],
    };

/// The RTP parameters of a track this phone sends. `mid`, `encodings` and `rtcp` are filled in once the offer exists.
Json getSendingRtpParameters(String kind, Json ext) {
  final params = <String, dynamic>{'codecs': <dynamic>[], 'headerExtensions': <dynamic>[], 'encodings': <dynamic>[], 'rtcp': <String, dynamic>{}};
  for (final c in (ext['codecs'] as List).cast<Json>()) {
    if (c['kind'] != kind) continue;
    (params['codecs'] as List).add(_noNulls({
      'mimeType': c['mimeType'],
      'payloadType': c['localPayloadType'],
      'clockRate': c['clockRate'],
      'channels': c['channels'],
      'parameters': c['localParameters'],
      'rtcpFeedback': c['rtcpFeedback'],
    }));
    if (c['localRtxPayloadType'] != null && c['localRtxPayloadType'] != 0) (params['codecs'] as List).add(_rtxOf(c));
  }
  for (final e in (ext['headerExtensions'] as List).cast<Json>()) {
    if ((e['kind'] != null && e['kind'] != kind) || (e['direction'] != 'sendrecv' && e['direction'] != 'sendonly')) continue;
    (params['headerExtensions'] as List).add({'uri': e['uri'], 'id': e['sendId'], 'encrypt': e['encrypt'], 'parameters': <String, dynamic>{}});
  }
  return params;
}

/// The same, as they belong in the answer the phone is told: the router's own parameters, with feedback reduced to what it supports.
Json getSendingRemoteRtpParameters(String kind, Json ext) {
  final params = <String, dynamic>{'codecs': <dynamic>[], 'headerExtensions': <dynamic>[], 'encodings': <dynamic>[], 'rtcp': <String, dynamic>{}};
  for (final c in (ext['codecs'] as List).cast<Json>()) {
    if (c['kind'] != kind) continue;
    (params['codecs'] as List).add(_noNulls({
      'mimeType': c['mimeType'],
      'payloadType': c['localPayloadType'],
      'clockRate': c['clockRate'],
      'channels': c['channels'],
      'parameters': c['remoteParameters'],
      'rtcpFeedback': c['rtcpFeedback'],
    }));
    if (c['localRtxPayloadType'] != null && c['localRtxPayloadType'] != 0) (params['codecs'] as List).add(_rtxOf(c));
  }
  for (final e in (ext['headerExtensions'] as List).cast<Json>()) {
    if ((e['kind'] != null && e['kind'] != kind) || (e['direction'] != 'sendrecv' && e['direction'] != 'sendonly')) continue;
    (params['headerExtensions'] as List).add({'uri': e['uri'], 'id': e['sendId'], 'encrypt': e['encrypt'], 'parameters': <String, dynamic>{}});
  }
  final uris = (params['headerExtensions'] as List).cast<Json>().map((e) => e['uri']).toSet();
  final drop = uris.contains('http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01')
      ? const {'goog-remb'}
      : uris.contains('http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time')
          ? const {'transport-cc'}
          : const {'transport-cc', 'goog-remb'};
  for (final c in (params['codecs'] as List).cast<Json>()) {
    c['rtcpFeedback'] = [for (final fb in ((c['rtcpFeedback'] ?? const []) as List).cast<Json>()) if (!drop.contains(fb['type'])) fb];
  }
  return params;
}

/// The first codec (and its RTX), or the one matching [wanted] when given. Needs codecs from [getSendingRtpParameters].
List<Json> reduceCodecs(List<Json> codecs, [Json? wanted]) {
  final out = <Json>[];
  if (wanted == null) {
    out.add(codecs[0]);
    if (codecs.length > 1 && isRtxCodec(codecs[1])) out.add(codecs[1]);
  } else {
    for (var i = 0; i < codecs.length; i++) {
      if (_matchCodecs(codecs[i], wanted, strict: true)) {
        out.add(codecs[i]);
        if (i + 1 < codecs.length && isRtxCodec(codecs[i + 1])) out.add(codecs[i + 1]);
        break;
      }
    }
    if (out.isEmpty) throw ArgumentError('no matching codec found');
  }
  return out;
}

/// Opus works with NACK in libwebrtc without saying so.
void addNackSupportForOpus(Json caps) {
  for (final c in (caps['codecs'] as List? ?? const []).cast<Json>()) {
    final mt = (c['mimeType'] as String).toLowerCase();
    if ((mt == 'audio/opus' || mt == 'audio/multiopus') && !((c['rtcpFeedback'] ?? const []) as List).cast<Json>().any((fb) => fb['type'] == 'nack' && _falsy(fb['parameter']))) {
      (c['rtcpFeedback'] ??= <dynamic>[] as dynamic).add({'type': 'nack'});
    }
  }
}

/// Lists a header extension the phone supports but does not announce, under the first free id.
void addHeaderExtensionSupport(Json caps, Json ext) {
  final list = (caps['headerExtensions'] ??= <dynamic>[] as dynamic) as List;
  if (list.cast<Json>().any((e) => e['kind'] == ext['kind'] && e['uri'] == ext['uri'])) return;
  final taken = list.cast<Json>().where((e) => e['uri'] != ext['uri']).map((e) => e['preferredId']).toSet();
  var id = 1;
  while (taken.contains(id)) {
    id++;
  }
  list.add({'kind': ext['kind'], 'uri': ext['uri'], 'preferredId': id, 'preferredEncrypt': false, 'direction': ext['direction']});
}

/// `msid` is `"<streamId> <trackId>"`.
({String? streamId, String? trackId}) msidParts(String? msid) {
  if (msid == null || msid.isEmpty) return (streamId: null, trackId: null);
  final parts = msid.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts[0].isEmpty) return (streamId: null, trackId: null);
  return (streamId: parts[0], trackId: parts.length > 1 ? parts[1] : null);
}

/// Whether this phone can receive what the server describes: its first codec is one the phone said it can take.
bool canReceive(Json rtpParameters, Json rtpCapabilities) {
  validateAndNormalizeRtpParameters(rtpParameters);
  final codecs = (rtpParameters['codecs'] as List).cast<Json>();
  if (codecs.isEmpty) return false;
  return ((rtpCapabilities['codecs'] ?? const []) as List).cast<Json>().any((c) => c['preferredPayloadType'] == codecs[0]['payloadType']);
}

Json cloneJson(Json j) => _clone(j);
