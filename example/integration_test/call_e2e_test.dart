// A real phone engine talking to the real servers: the Android emulator's libwebrtc, our gateway and our mediasoup media server, with a
// Chrome on the other side. It receives Chrome's microphone and camera, sends its own, mutes, and leaves. The numbers it prints are
// read back by apps/media-core's `media.flutter.spec.ts`, which also asks Chrome what it saw.
//
// Run from that spec; it passes WS_URL and TOKEN.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zapiack/zapiack.dart';

const wsUrl = String.fromEnvironment('WS_URL');
const token = String.fromEnvironment('TOKEN');

/// Off when only receiving is wanted (a desktop with no camera or microphone to give).
const sendMedia = bool.fromEnvironment('SEND', defaultValue: true);

Future<void> until(bool Function() ok, String what, {int seconds = 40}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('joins, receives, sends, mutes and leaves against the real media server', (tester) async {
    final call = createZapiackCall(getToken: () async => token, url: Uri.parse(wsUrl));
    final received = <String>[];
    final errors = <String>[];
    final peers = <String>[];
    final paused = <String>[];
    call.tracks.listen((t) => received.add('${t.identity}:${t.source.name}'));
    call.errors.listen((e) => errors.add(e.message));
    call.peerJoined.listen((p) => peers.add(p.identity));
    call.paused.listen((p) => paused.add('${p.source.name}:${p.paused}'));

    final joined = await call.join();
    await until(() => received.length >= 2, "ada's microphone and camera");
    // Media can take a few seconds to start on an emulator: wait for it, and show the numbers while waiting.
    var stats = await call.stats();
    for (var i = 0; i < 15 && !stats.every((s) => s.bytesReceived > (s.source == TrackSource.audio ? 0 : 2000)); i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      stats = await call.stats();
      // ignore: avoid_print
      print('E2E STATS ${stats.map((s) => '${s.source.name}: ${s.bytesReceived} bytes, ${s.packetsReceived} packets, ${s.packetsLost} lost').join(' | ')}');
    }
    if (!stats.every((s) => s.bytesReceived > (s.source == TrackSource.audio ? 0 : 2000))) {
      for (final dir in [true, false]) {
        final all = await call.connectionStats(receiving: dir);
        // ignore: avoid_print
        print('E2E CONN ${dir ? 'recv' : 'send'} types=${all.map((r) => r['type']).toSet()}');
        for (final r in all) {
          if (r['type'] == 'candidate-pair' || r['type'] == 'inbound-rtp' || r['type'] == 'outbound-rtp' || r['type'] == 'transport') {
            // ignore: avoid_print
            print('E2E CONN ${r['type']} ${r.entries.where((x) => const {'state', 'bytesReceived', 'bytesSent', 'packetsReceived', 'packetsSent', 'nominated', 'kind', 'mediaType', 'selected', 'dtlsState', 'iceState', 'writable'}.contains(x.key)).map((x) => '${x.key}=${x.value}').join(',')}');
          }
        }
      }
      final raw = await call.rawStats();
      for (final e in raw.entries) {
        // ignore: avoid_print
        print('E2E RAW ${e.key}: ${e.value.map((r) => '${r['type']}{${r.entries.where((x) => x.key.toString().contains('ytes') || x.key.toString().contains('ackets') || x.key == 'kind' || x.key == 'mediaType').map((x) => '${x.key}=${x.value}').join(',')}}').join(' ')}');
      }
    }
    final flowing = {for (final s in stats) '${s.identity}:${s.source.name}': s.bytesReceived > (s.source == TrackSource.audio ? 0 : 2000)};

    if (sendMedia) {
      await call.enableMicrophone();
      await call.enableCamera();
    }
    final sending = call.sending.map((s) => s.name).toList()..sort();
    // Chrome measures what arrives from here while this holds.
    await Future<void>.delayed(const Duration(seconds: 12));

    var mutedWhileMuted = true;
    if (sendMedia) {
      await call.setMuted(TrackSource.audio, true);
      await Future<void>.delayed(const Duration(seconds: 2));
      mutedWhileMuted = call.isMuted(TrackSource.audio);
      await call.setMuted(TrackSource.audio, false);
      await Future<void>.delayed(const Duration(seconds: 2));
      await call.stop(TrackSource.video);
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    await call.leave();

    final result = {
      'role': joined.role.name,
      'roomId': joined.roomId,
      'members': joined.members.map((m) => m.identity).toList(),
      'received': (received..sort()),
      'flowing': flowing,
      'sending': sending,
      'errors': errors,
      'mutedWhileMuted': mutedWhileMuted,
      'state': call.state.name,
    };
    // ignore: avoid_print
    print('E2E RESULT ${jsonEncode(result)}');

    expect(errors, isEmpty);
    expect(received, ['ada:audio', 'ada:video']);
    expect(flowing.values, everyElement(isTrue), reason: 'media is really arriving: $stats');
    expect(sending, sendMedia ? ['audio', 'video'] : isEmpty);
    expect(mutedWhileMuted, isTrue);
    expect(call.state, CallState.closed);
  });
}
