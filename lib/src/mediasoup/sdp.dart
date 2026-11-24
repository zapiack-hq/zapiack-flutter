// The SDP the mediasoup protocol needs, read and written the way `sdp-transform` does: a session is a map, each media section is
// a map, and the keys are the same ones (`rtp`, `fmtp`, `rtcpFb`, `ext`, `ssrcs`, ...). That keeps this port line for line with the
// JavaScript client it must agree with, which the golden tests check byte for byte.
//
// Only what an audio and video call uses is understood. Anything else in a local SDP is ignored; nothing is ever written that the
// server's own SDP builder would not.
//
// Derived from mediasoup-client (ISC licence, Copyright (c) 2015, Iñaki Baz Castillo and contributors) and sdp-transform (MIT).
library;

/// A number when it reads back the same, as `sdp-transform` does: `"111"` is 111, `"007"` stays a string.
Object toIntIfInt(String v) {
  final n = int.tryParse(v);
  if (n != null && n.toString() == v) return n;
  final d = double.tryParse(v);
  if (d != null && d % 1 != 0 && d.toString() == v) return d;
  return v;
}

/// `a=fmtp` configuration, `key=value;key=value`, as a map. Numbers stay numbers.
Map<String, Object?> parseParams(String str) {
  final out = <String, Object?>{};
  for (final expr in str.split(RegExp(r';\s?'))) {
    final eq = expr.indexOf('=');
    if (eq >= 0 && eq < expr.length - 1) {
      out[expr.substring(0, eq)] = toIntIfInt(expr.substring(eq + 1));
    } else if (expr.length > 1) {
      out[expr] = null;
    }
  }
  return out;
}

final _rtpmap = RegExp(r'^rtpmap:(\d+) ([\w\-.]*)(?:\s*/(\d*)(?:\s*/(\S*))?)?');
final _fmtp = RegExp(r'^fmtp:(\d+) (.*)$');
final _rtcpFb = RegExp(r'^rtcp-fb:(\*|\d+) ([\w\-_]*)(?: ([\w\-_]*))?');
final _extmap = RegExp(r'^extmap:(\d+)(?:/(\w+))?(?: (urn:ietf:params:rtp-hdrext:encrypt))? (\S*)(?: (\S*))?');
final _ssrc = RegExp(r'^ssrc:(\d+) ([\w_\-]*)(?::(.*))?');
final _ssrcGroup = RegExp(r'^ssrc-group:([\x21\x23\x24\x25\x26\x27\x2A\x2B\x2D\x2E\w]*) (.*)');
final _fingerprint = RegExp(r'^fingerprint:(\S*) (\S*)');
final _group = RegExp(r'^group:(\S*)(?: (.*))?');
final _msid = RegExp(r'^msid:(\S*) ?(\S*)?');

/// Reads an SDP into the shape `sdp-transform` gives: session keys at the top, a `media` list below.
Map<String, dynamic> parseSdp(String sdp) {
  final session = <String, dynamic>{'media': <Map<String, dynamic>>[]};
  Map<String, dynamic> at = session;
  for (final raw in sdp.split(RegExp(r'\r?\n'))) {
    if (raw.length < 3 || raw[1] != '=') continue;
    final type = raw[0];
    final content = raw.substring(2);
    if (type == 'm') {
      final parts = content.split(' ');
      at = <String, dynamic>{
        'type': parts[0],
        'port': int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
        'protocol': parts.length > 2 ? parts[2] : '',
        'payloads': parts.length > 3 ? parts.sublist(3).join(' ') : '',
      };
      (session['media'] as List).add(at);
      continue;
    }
    if (type == 'c') {
      final m = RegExp(r'^IN IP(\d) (\S*)').firstMatch(content);
      if (m != null) at['connection'] = {'version': int.parse(m.group(1)!), 'ip': m.group(2)};
      continue;
    }
    if (type != 'a') continue;

    RegExpMatch? m;
    if ((m = _rtpmap.firstMatch(content)) != null) {
      (at['rtp'] ??= <Map<String, dynamic>>[] as dynamic).add(<String, dynamic>{
        'payload': int.parse(m!.group(1)!),
        'codec': m.group(2),
        if (m.group(3) != null) 'rate': toIntIfInt(m.group(3)!),
        if (m.group(4) != null) 'encoding': toIntIfInt(m.group(4)!),
      });
    } else if ((m = _fmtp.firstMatch(content)) != null) {
      (at['fmtp'] ??= <Map<String, dynamic>>[] as dynamic).add({'payload': int.parse(m!.group(1)!), 'config': m.group(2)});
    } else if ((m = _rtcpFb.firstMatch(content)) != null) {
      (at['rtcpFb'] ??= <Map<String, dynamic>>[] as dynamic).add(<String, dynamic>{
        'payload': m!.group(1) == '*' ? '*' : int.parse(m.group(1)!),
        'type': m.group(2),
        if (m.group(3) != null) 'subtype': m.group(3),
      });
    } else if ((m = _extmap.firstMatch(content)) != null) {
      (at['ext'] ??= <Map<String, dynamic>>[] as dynamic).add(<String, dynamic>{
        'value': int.parse(m!.group(1)!),
        if (m.group(2) != null) 'direction': m.group(2),
        if (m.group(3) != null) 'encrypt-uri': m.group(3),
        'uri': m.group(4),
        if (m.group(5) != null) 'config': m.group(5),
      });
    } else if (content == 'extmap-allow-mixed') {
      at['extmapAllowMixed'] = 'extmap-allow-mixed';
    } else if (content.startsWith('setup:')) {
      at['setup'] = content.substring(6);
    } else if (content.startsWith('mid:')) {
      at['mid'] = content.substring(4);
    } else if ((m = _msid.firstMatch(content)) != null) {
      (at['msid'] ??= <Map<String, dynamic>>[] as dynamic).add({'id': m!.group(1), 'appdata': m.group(2)});
    } else if (const {'sendrecv', 'sendonly', 'recvonly', 'inactive'}.contains(content)) {
      at['direction'] = content;
    } else if ((m = _fingerprint.firstMatch(content)) != null) {
      at['fingerprint'] = {'type': m!.group(1), 'hash': m.group(2)};
    } else if ((m = _ssrcGroup.firstMatch(content)) != null) {
      (at['ssrcGroups'] ??= <Map<String, dynamic>>[] as dynamic).add({'semantics': m!.group(1), 'ssrcs': m.group(2)});
    } else if ((m = _ssrc.firstMatch(content)) != null) {
      (at['ssrcs'] ??= <Map<String, dynamic>>[] as dynamic).add(<String, dynamic>{
        'id': int.parse(m!.group(1)!),
        'attribute': m.group(2),
        if (m.group(3) != null) 'value': m.group(3),
      });
    } else if ((m = _group.firstMatch(content)) != null) {
      (at['groups'] ??= <Map<String, dynamic>>[] as dynamic).add({'type': m!.group(1), 'mids': m.group(2) ?? ''});
    } else if (content.startsWith('ice-ufrag:')) {
      at['iceUfrag'] = content.substring(10);
    } else if (content.startsWith('ice-pwd:')) {
      at['icePwd'] = content.substring(8);
    }
  }
  return session;
}

/// Writes the session the way `sdp-transform` does, attribute for attribute in its order, with `\r\n` line ends.
String writeSdp(Map<String, dynamic> s) {
  final out = <String>['v=${s['version'] ?? 0}'];
  final o = s['origin'] as Map<String, dynamic>;
  out.add('o=${o['username']} ${o['sessionId']} ${o['sessionVersion']} ${o['netType']} IP${o['ipVer']} ${o['address']}');
  out.add('s=${s['name']}');
  final t = s['timing'] as Map<String, dynamic>;
  out.add('t=${t['start']} ${t['stop']}');
  _attributes(out, s, session: true);
  for (final m in (s['media'] as List).cast<Map<String, dynamic>>()) {
    out.add('m=${m['type']} ${m['port']} ${m['protocol']} ${m['payloads']}');
    final c = m['connection'] as Map<String, dynamic>?;
    if (c != null) out.add('c=IN IP${c['version']} ${c['ip']}');
    _attributes(out, m, session: false);
  }
  return '${out.join('\r\n')}\r\n';
}

void _attributes(List<String> out, Map<String, dynamic> m, {required bool session}) {
  for (final r in (m['rtp'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    out.add('a=rtpmap:${r['payload']} ${r['codec']}/${r['rate']}${r['encoding'] != null ? '/${r['encoding']}' : ''}');
  }
  for (final f in (m['fmtp'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    out.add('a=fmtp:${f['payload']} ${f['config']}');
  }
  for (final f in (m['rtcpFb'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    // A feedback with an empty parameter keeps its trailing space, as the JavaScript writer leaves it.
    out.add(f['subtype'] != null ? 'a=rtcp-fb:${f['payload']} ${f['type']} ${f['subtype']}' : 'a=rtcp-fb:${f['payload']} ${f['type']}');
  }
  for (final e in (m['ext'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    out.add('a=extmap:${e['value']}${e['direction'] != null ? '/${e['direction']}' : ''}${e['encrypt-uri'] != null ? ' ${e['encrypt-uri']}' : ''} ${e['uri']}${e['config'] != null ? ' ${e['config']}' : ''}');
  }
  if (m['extmapAllowMixed'] != null) out.add('a=extmap-allow-mixed');
  if (m['setup'] != null) out.add('a=setup:${m['setup']}');
  if (m['mid'] != null) out.add('a=mid:${m['mid']}');
  for (final x in (m['msid'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    out.add('a=msid:${x['id']}${x['appdata'] != null ? ' ${x['appdata']}' : ''}');
  }
  if (m['direction'] != null) out.add('a=${m['direction']}');
  if (m['icelite'] != null) out.add('a=ice-lite');
  if (m['iceUfrag'] != null) out.add('a=ice-ufrag:${m['iceUfrag']}');
  if (m['icePwd'] != null) out.add('a=ice-pwd:${m['icePwd']}');
  final fp = m['fingerprint'] as Map<String, dynamic>?;
  if (fp != null) out.add('a=fingerprint:${fp['type']} ${fp['hash']}');
  for (final c in (m['candidates'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    out.add('a=candidate:${c['foundation']} ${c['component']} ${c['transport']} ${c['priority']} ${c['ip']} ${c['port']} typ ${c['type']}${c['tcptype'] != null ? ' tcptype ${c['tcptype']}' : ''}');
  }
  if (m['endOfCandidates'] != null) out.add('a=end-of-candidates');
  if (m['iceOptions'] != null) out.add('a=ice-options:${m['iceOptions']}');
  for (final x in (m['ssrcs'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    out.add('a=ssrc:${x['id']} ${x['attribute']}${x['value'] != null ? ':${x['value']}' : ''}');
  }
  for (final x in (m['ssrcGroups'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    out.add('a=ssrc-group:${x['semantics']} ${x['ssrcs']}');
  }
  for (final g in (m['groups'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    out.add('a=group:${g['type']} ${g['mids']}');
  }
  if (m['rtcpMux'] != null) out.add('a=rtcp-mux');
  if (m['rtcpRsize'] != null) out.add('a=rtcp-rsize');
}
