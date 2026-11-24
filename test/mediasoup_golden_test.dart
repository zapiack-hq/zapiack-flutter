// The Dart client against the JavaScript one. `test/fixtures/mediasoup_golden.json` holds what the real mediasoup-client computed for
// the capabilities of a real mediasoup router and the SDP of a real Chrome (see tool/golden/generate.cjs). The same inputs go into
// this port and the answers must be identical, down to the characters of the SDP the server's side is described with.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zapiack/src/mediasoup/handler.dart';
import 'package:zapiack/src/mediasoup/ortc.dart';
import 'package:zapiack/src/mediasoup/sdp.dart';

import 'support/fake_link.dart';

late final Json g;
Json c(Object? v) => deepCopy(v as Json);
List<Json> list(Object? v) => (v as List).cast<Json>();

void main() {
  setUpAll(() => g = jsonDecode(File('test/fixtures/mediasoup_golden.json').readAsStringSync()) as Json);

  group('what the engine can do', () {
    test('reads the native capabilities out of a real Chrome offer', () {
      final caps = localRtpCapabilities(parseSdp((g['sdps'] as Json)['native'] as String));
      expect(caps, equals(g['nativeCaps']));
    });

    test('matches them against the router: the shared codecs, RTX and header extensions, in the router\'s order', () {
      final ext = getExtendedRtpCapabilities(c(g['nativeCaps']), c(g['routerRtpCapabilities']));
      expect(ext, equals(g['extended']));
    });

    test('says what this phone can receive', () {
      final ext = getExtendedRtpCapabilities(c(g['nativeCaps']), c(g['routerRtpCapabilities']));
      expect(getRecvRtpCapabilities(ext), equals(g['recvCaps']));
    });
  });

  group('sending', () {
    test('every step produces the same RTP parameters and the same remote SDP as mediasoup-client', () async {
      final send = g['send'] as Json;
      final steps = list(send['steps']);
      final link = FakeLink(offers: [for (final s in steps) s['offerSdp'] as String]);
      final connects = <Json>[];
      final h = Handler(
        direction: 'send',
        iceParameters: c((send['transportParams'] as Json)['iceParameters']),
        iceCandidates: (c(send['transportParams'] as Json)['iceCandidates'] as List),
        dtlsParameters: c((send['transportParams'] as Json)['dtlsParameters']),
        link: link,
        getSendExtendedRtpCapabilities: (native) => getExtendedRtpCapabilities(native, c(g['routerRtpCapabilities'])),
        onConnect: (d) async => connects.add(d),
      );
      for (final step in steps) {
        final kind = step['kind'] as String;
        final r = await h.send(track: FakeTrack(kind), streamId: 'stream-1', codecOptions: step['codecOptions'] == null ? null : c(step['codecOptions']));
        expect(r.rtpParameters, equals(step['expectParams']), reason: '$kind parameters');
        expect(link.log.where((l) => l.op == 'setRemote' && l.type == 'answer').last.sdp, equals(step['expectRemoteSdp']), reason: '$kind remote SDP');
      }
      expect(connects, [send['dtlsParameters']], reason: 'the transport connects once, with the engine\'s DTLS parameters');
    });

    test('restarting ICE swaps in the new credentials and negotiates again', () async {
      final send = g['send'] as Json;
      final steps = list(send['steps']);
      final link = FakeLink(offers: [for (final s in steps) s['offerSdp'] as String]);
      final h = Handler(
        direction: 'send',
        iceParameters: c((send['transportParams'] as Json)['iceParameters']),
        iceCandidates: (c(send['transportParams'] as Json)['iceCandidates'] as List),
        dtlsParameters: c((send['transportParams'] as Json)['dtlsParameters']),
        link: link,
        getSendExtendedRtpCapabilities: (native) => getExtendedRtpCapabilities(native, c(g['routerRtpCapabilities'])),
        onConnect: (_) async {},
      );
      for (final step in steps) {
        await h.send(track: FakeTrack(step['kind'] as String), streamId: 'stream-1', codecOptions: step['codecOptions'] == null ? null : c(step['codecOptions']));
      }
      await h.restartIce(c((g['restart'] as Json)['iceParameters']));
      expect(link.log.last.sdp, equals((g['restart'] as Json)['expectRemoteSdp']));
      expect(link.log.where((l) => l.op == 'createOffer').last.type, 'restart');
    });
  });

  group('receiving', () {
    test('describes each track the server will send the way mediasoup-client does', () async {
      final recv = g['recv'] as Json;
      final consumers = list(recv['consumers']);
      final link = FakeLink(answers: [recv['answerSdp'] as String]);
      final h = Handler(
        direction: 'recv',
        iceParameters: c((recv['transportParams'] as Json)['iceParameters']),
        iceCandidates: (c(recv['transportParams'] as Json)['iceCandidates'] as List),
        dtlsParameters: c((recv['transportParams'] as Json)['dtlsParameters']),
        link: link,
        getSendExtendedRtpCapabilities: (_) => throw StateError('a receiving transport never sends'),
        onConnect: (_) async {},
      );
      final steps = list(recv['steps']);
      for (var i = 0; i < consumers.length; i++) {
        final k = consumers[i];
        final out = await h.receive([ReceiveItem(trackId: k['id'] as String, kind: k['kind'] as String, rtpParameters: c(k['rtpParameters']))]);
        expect(out.single.localId, steps[i]['mid']);
        expect(link.log.where((l) => l.op == 'setRemote' && l.type == 'offer').last.sdp, equals(steps[i]['expectRemoteOffer']), reason: 'offer for consumer $i');
      }
    });

    test('reads the DTLS parameters the engine put in its answer, and connects once as the client', () async {
      final recv = g['recv'] as Json;
      final consumers = list(recv['consumers']);
      final link = FakeLink(answers: [recv['answerSdp'] as String]);
      final connects = <Json>[];
      final h = Handler(
        direction: 'recv',
        iceParameters: c((recv['transportParams'] as Json)['iceParameters']),
        iceCandidates: (c(recv['transportParams'] as Json)['iceCandidates'] as List),
        dtlsParameters: c((recv['transportParams'] as Json)['dtlsParameters']),
        link: link,
        getSendExtendedRtpCapabilities: (_) => throw StateError('never'),
        onConnect: (d) async => connects.add(d),
      );
      await h.receive([for (final k in consumers) ReceiveItem(trackId: k['id'] as String, kind: k['kind'] as String, rtpParameters: c(k['rtpParameters']))]);
      expect(connects, [recv['expectDtls']]);
    });

    test('keeps what the engine answered, and changes only the Opus lines the sender asked for', () async {
      final recv = g['recv'] as Json;
      final consumers = list(recv['consumers']);
      final link = FakeLink(answers: [recv['answerSdp'] as String]);
      final h = Handler(
        direction: 'recv',
        iceParameters: c((recv['transportParams'] as Json)['iceParameters']),
        iceCandidates: (c(recv['transportParams'] as Json)['iceCandidates'] as List),
        dtlsParameters: c((recv['transportParams'] as Json)['dtlsParameters']),
        link: link,
        getSendExtendedRtpCapabilities: (_) => throw StateError('never'),
        onConnect: (_) async {},
      );
      await h.receive([for (final k in consumers) ReceiveItem(trackId: k['id'] as String, kind: k['kind'] as String, rtpParameters: c(k['rtpParameters']))]);
      final sent = parseSdp(link.log.firstWhere((l) => l.op == 'setLocal').sdp);
      final expected = parseSdp(recv['expectAnswerAfterCodecParameters'] as String);
      // The same media sections, with the same codecs and parameters, as the JavaScript client's answer.
      for (var i = 0; i < (expected['media'] as List).length; i++) {
        final a = (sent['media'] as List)[i] as Json, b = (expected['media'] as List)[i] as Json;
        expect(a['mid'], b['mid']);
        expect(a['rtp'], equals(b['rtp']));
        expect(a['fmtp'], equals(b['fmtp']));
        expect(a['rtcpFb'], equals(b['rtcpFb']));
      }
    });
  });
}
