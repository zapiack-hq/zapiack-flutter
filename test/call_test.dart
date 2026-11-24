// The call itself: joining, sending, receiving, muting, the room changing, the network changing. The negotiation underneath is the
// real one, fed the real SDP and router data from the golden file; only the network and the engine are faked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zapiack/zapiack.dart';
import 'package:zapiack/src/mediasoup/link.dart';

import 'support/fake_link.dart';

late final Map<String, dynamic> g;

class FakeSignal implements CallSignal {
  final asked = <(String, Map<String, Object?>)>[];
  final answers = <String, Object? Function(Map<String, Object?>)>{};
  final _room = StreamController<RealtimeMessage>.broadcast(sync: true);
  final _states = StreamController<RealtimeState>.broadcast(sync: true);
  bool disconnected = false;
  final subscribed = <String>[];

  @override
  Future<void> connect() async {}
  @override
  void disconnect() => disconnected = true;
  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, Object?> data = const {}]) async {
    asked.add((method, data));
    final a = answers[method];
    if (a == null) return {};
    final r = a(data);
    return (r as Map).cast<String, dynamic>();
  }

  @override
  Stream<RealtimeMessage> subscribe(String channel) {
    subscribed.add(channel);
    return _room.stream;
  }

  @override
  Stream<RealtimeState> get states => _states.stream;

  void room(String event, Map<String, dynamic> data) => _room.add(RealtimeMessage(msgId: 'm', ts: 0, channel: 'call:room-1', event: event, data: data));
  void line(RealtimeState s) => _states.add(s);
  List<String> get methods => [for (final a in asked) a.$1];
}

class FakeMedia implements CallMedia {
  final tracks = <FakeTrack>[];
  final calls = <String>[];
  @override
  Future<MediaTrack> microphone() async => _t(FakeTrack('audio'));
  @override
  Future<MediaTrack> camera({required bool front}) async {
    calls.add('camera:${front ? 'front' : 'back'}');
    return _t(FakeTrack('video'));
  }

  @override
  Future<MediaTrack> screen() async => _t(FakeTrack('video', 'track-screen'));
  @override
  Future<void> setSpeaker(bool on) async => calls.add('speaker:$on');
  @override
  Future<void> switchCamera(MediaTrack track) async => calls.add('switch:${track.id}');
  @override
  Future<Object> streamOf(MediaTrack track) async => 'stream-of-${track.id}';
  FakeTrack _t(FakeTrack t) {
    tracks.add(t);
    return t;
  }
}

class Rig {
  Rig({Map<String, dynamic> join = const {}, this.grace = const Duration(milliseconds: 20), this.resync = Duration.zero}) {
    final recv = g['recv'] as Map<String, dynamic>;
    final send = g['send'] as Map<String, dynamic>;
    var n = 0;
    signal.answers['media.join'] = (_) => {
          'roomId': 'room-1',
          'identity': 'me',
          'routerRtpCapabilities': g['routerRtpCapabilities'],
          'iceServers': <dynamic>[],
          'role': 'speaker',
          'peers': <dynamic>[],
          ...join,
        };
    signal.answers['media.createTransport'] = (d) {
      final p = (d['direction'] == 'send' ? send : recv)['transportParams'] as Map<String, dynamic>;
      return {'id': 't${++n}', ...p};
    };
    signal.answers['media.produce'] = (_) => {'id': 'p${++n}'};
    final consumers = (recv['consumers'] as List).cast<Map<String, dynamic>>();
    signal.answers['media.consume'] = (d) {
      final audio = d['producerId'].toString().contains('a');
      final c = consumers[audio ? 0 : 1];
      return {
        'id': c['id'],
        'producerId': d['producerId'],
        'kind': c['kind'],
        'source': audio ? 'audio' : 'video',
        'identity': 'ada',
        'rtpParameters': c['rtpParameters'],
      };
    };
    signal.answers['media.restartIce'] = (_) => {'iceParameters': (g['restart'] as Map)['iceParameters']};
    factory = FakeFactory(
      native: (g['sdps'] as Map)['native'] as String,
      offerBySequence: {for (final k in ['a', 'v', 'av', 'va', 'avv', 'vv', 'ava']) k: (g['sdps'] as Map)[k] as String},
      answers: [recv['answerSdp'] as String],
    );
    call = ZapiackCall(getToken: () async => 'tok', signal: signal, factory: factory, media: media, disconnectedGrace: grace, resyncEvery: resync);
  }

  final Duration grace;
  final Duration resync;
  final signal = FakeSignal();
  final media = FakeMedia();
  late final FakeFactory factory;
  late final ZapiackCall call;
}

Future<void> tick([int ms = 0]) => Future<void>.delayed(Duration(milliseconds: ms));
Map<String, dynamic> ada() => {
      'identity': 'ada',
      'role': 'host',
      'producers': [
        {'id': 'p-a', 'kind': 'audio', 'paused': false},
        {'id': 'p-v', 'kind': 'video', 'paused': false},
      ],
    };

void main() {
  setUpAll(() => g = jsonDecode(File('test/fixtures/mediasoup_golden.json').readAsStringSync()) as Map<String, dynamic>);

  group('joining', () {
    test('connects, joins, loads the device, listens to the room, and joins again to see anything that changed in between', () async {
      final r = Rig();
      final out = await r.call.join();
      expect(out.role, CallRole.speaker);
      expect(out.roomId, 'room-1');
      expect(r.signal.methods, ['media.join', 'media.join']);
      expect(r.signal.subscribed, ['call:room-1']);
      expect(r.call.state, CallState.joined);
    });

    test('receives what others are already sending, and tells the app', () async {
      final r = Rig(join: {'peers': [ada()]});
      final tracks = <String>[], peers = <String>[];
      r.call.tracks.listen((t) => tracks.add('${t.identity}:${t.source.name}'));
      r.call.peerJoined.listen((p) => peers.add(p.identity));
      await r.call.join();
      await tick();
      expect(peers, ['ada']);
      expect(tracks..sort(), ['ada:audio', 'ada:video']);
      // One receive transport, the track asked for with this device's capabilities, then resumed.
      expect(r.signal.methods.where((m) => m == 'media.createTransport'), hasLength(1));
      expect(r.signal.asked.firstWhere((a) => a.$1 == 'media.consume').$2['rtpCapabilities'], equals(g['recv']['recvRtpCapabilities']));
      expect(r.signal.methods, contains('media.resumeConsumer'));
      expect(r.signal.methods, contains('media.connectTransport'));
    });

    test('closes everything and reports the problem when the join is refused', () async {
      final r = Rig();
      r.signal.answers['media.join'] = (_) => throw const CallException('This token is not for a call.', 'forbidden');
      await expectLater(r.call.join(), throwsA(isA<CallException>().having((e) => e.reason, 'reason', 'forbidden')));
      expect(r.call.state, CallState.closed);
      expect(r.signal.disconnected, isTrue);
    });
  });

  group('sending', () {
    test('the microphone: a send transport is made and connected once, and the server is told the audio, with the engine\'s parameters', () async {
      final r = Rig();
      await r.call.join();
      final t = await r.call.enableMicrophone();
      expect(r.call.sending, [TrackSource.audio]);
      final produce = r.signal.asked.firstWhere((a) => a.$1 == 'media.produce').$2;
      expect(produce['kind'], 'audio');
      expect((produce['rtpParameters'] as Map)['mid'], '0');
      expect(((produce['rtpParameters'] as Map)['codecs'] as List).first['mimeType'], 'audio/opus');
      expect(r.signal.methods.where((m) => m == 'media.connectTransport'), hasLength(1));
      expect(t.enabled, isTrue);
    });

    test('a camera after the microphone shares the transport and its connection', () async {
      final r = Rig();
      await r.call.join();
      await r.call.enableMicrophone();
      await r.call.enableCamera();
      expect(r.call.sending, containsAll([TrackSource.audio, TrackSource.video]));
      expect(r.signal.methods.where((m) => m == 'media.createTransport'), hasLength(1));
      expect(r.signal.methods.where((m) => m == 'media.connectTransport'), hasLength(1));
      expect(r.signal.asked.where((a) => a.$1 == 'media.produce').map((a) => a.$2['kind']), ['audio', 'video']);
    });

    test('a listener may receive but never send', () async {
      final r = Rig(join: {'role': 'listener'});
      await r.call.join();
      await expectLater(r.call.enableMicrophone(), throwsA(isA<CallException>().having((e) => e.reason, 'reason', 'forbidden')));
      expect(r.call.sending, isEmpty);
    });

    test('sending before joining is refused', () async {
      final r = Rig();
      await expectLater(r.call.enableMicrophone(), throwsA(isA<CallException>()));
    });

    test('muting sends nothing and tells the server, and unmuting reverses it', () async {
      final r = Rig();
      await r.call.join();
      final t = await r.call.enableMicrophone();
      await r.call.setMuted(TrackSource.audio, true);
      expect(t.enabled, isFalse);
      expect(r.call.isMuted(TrackSource.audio), isTrue);
      expect(r.signal.methods, contains('media.pauseProducer'));
      await r.call.setMuted(TrackSource.audio, false);
      expect(t.enabled, isTrue);
      expect(r.signal.methods, contains('media.resumeProducer'));
    });

    test('stopping a track closes it on the server and lets go of the device', () async {
      final r = Rig();
      await r.call.join();
      final t = await r.call.enableCamera() as FakeTrack;
      await r.call.stop(TrackSource.video);
      expect(t.stopped, isTrue);
      expect(r.call.sending, isEmpty);
      expect(r.signal.methods, contains('media.closeProducer'));
    });

    test('a refused produce leaves nothing half-sent', () async {
      final r = Rig();
      await r.call.join();
      r.signal.answers['media.produce'] = (_) => throw const CallException('no', 'forbidden');
      await expectLater(r.call.enableMicrophone(), throwsA(isA<CallException>()));
      expect(r.call.sending, isEmpty);
    });
  });

  group('the room changing', () {
    test('a person arriving, then their track, then leaving: everything they brought goes with them', () async {
      final r = Rig();
      final log = <String>[];
      r.call.peerJoined.listen((p) => log.add('+${p.identity}'));
      r.call.tracks.listen((t) => log.add('track:${t.source.name}'));
      r.call.trackEnded.listen((t) => log.add('ended:${t.source.name}'));
      r.call.peerLeft.listen((p) => log.add('-$p'));
      await r.call.join();
      r.signal.room('peerJoined', {'identity': 'ada', 'role': 'host'});
      r.signal.room('newProducer', {'identity': 'ada', 'producerId': 'p-a', 'kind': 'audio'});
      await tick(5);
      r.signal.room('peerLeft', {'identity': 'ada'});
      expect(log, ['+ada', 'track:audio', 'ended:audio', '-ada']);
    });

    test('events about this person are ignored', () async {
      final r = Rig();
      final log = <String>[];
      r.call.peerJoined.listen((p) => log.add(p.identity));
      await r.call.join();
      r.signal.room('peerJoined', {'identity': 'me', 'role': 'speaker'});
      r.signal.room('newProducer', {'identity': 'me', 'producerId': 'p-a', 'kind': 'audio'});
      await tick(5);
      expect(log, isEmpty);
      expect(r.signal.methods, isNot(contains('media.consume')));
    });

    test('someone else muting is passed on, and a track that arrives already muted says so', () async {
      final r = Rig(join: {'peers': [ada()]});
      final log = <String>[];
      r.call.paused.listen((p) => log.add('${p.source.name}:${p.paused}'));
      await r.call.join();
      await tick();
      r.signal.room('producerPaused', {'producerId': 'p-a', 'paused': true});
      r.signal.room('producerClosed', {'producerId': 'p-v'});
      expect(log, ['audio:true']);
    });

    test('two events for the same track make one consumer', () async {
      final r = Rig();
      await r.call.join();
      r.signal.room('newProducer', {'identity': 'ada', 'producerId': 'p-a', 'kind': 'audio'});
      r.signal.room('newProducer', {'identity': 'ada', 'producerId': 'p-a', 'kind': 'audio'});
      await tick(10);
      expect(r.signal.methods.where((m) => m == 'media.consume'), hasLength(1));
    });

    test('the room being ended closes the call and says so', () async {
      final r = Rig();
      final ended = <String>[];
      r.call.ended.listen((e) => ended.add(e.reason));
      await r.call.join();
      await r.call.enableMicrophone();
      r.signal.room('roomEnded', {'reason': 'ended_by_host'});
      await tick(5);
      expect(ended, ['ended_by_host']);
      expect(r.call.state, CallState.closed);
      expect(r.signal.disconnected, isTrue);
      expect((r.media.tracks.first).stopped, isTrue);
    });
  });

  group('on a phone', () {
    test('opens the front camera, and the back one when asked; switching flips the live camera and the next one opened', () async {
      final r = Rig();
      await r.call.join();
      await r.call.enableCamera();
      expect(r.media.calls, ['camera:front']);
      await r.call.switchCamera();
      expect(r.media.calls.last, 'switch:track-video');
      await r.call.stop(TrackSource.video);
      await r.call.enableCamera();
      expect(r.media.calls.last, 'camera:back');
    });

    test('switching with no camera on is an error', () async {
      final r = Rig();
      await r.call.join();
      await expectLater(r.call.switchCamera(), throwsA(isA<CallException>()));
    });

    test('the speaker choice is passed on, and remembered for a call joined later', () async {
      final r = Rig();
      await r.call.setSpeaker(true);
      await r.call.join();
      expect(r.media.calls, ['speaker:true', 'speaker:true']);
    });

    test('a path that stays disconnected is restarted with fresh parameters; one that comes back by itself is left alone', () async {
      final r = Rig();
      await r.call.join();
      await r.call.enableMicrophone();
      final link = r.factory.links.first;
      link.onConnectionState!('disconnected');
      link.onConnectionState!('connected');
      await tick(60);
      expect(r.signal.methods, isNot(contains('media.restartIce')));

      link.onConnectionState!('disconnected');
      await tick(80);
      expect(r.signal.methods, contains('media.restartIce'));
      expect(link.log.where((l) => l.op == 'createOffer').last.type, 'restart');
    });

    test('a failed path is restarted at once', () async {
      final r = Rig(grace: const Duration(seconds: 30));
      await r.call.join();
      await r.call.enableMicrophone();
      r.factory.links.first.onConnectionState!('failed');
      await tick(20);
      expect(r.signal.methods, contains('media.restartIce'));
    });

    test('a pending restart is dropped when the call is left', () async {
      final r = Rig();
      await r.call.join();
      await r.call.enableMicrophone();
      r.factory.links.first.onConnectionState!('disconnected');
      await r.call.leave();
      await tick(80);
      expect(r.signal.methods, isNot(contains('media.restartIce')));
    });
  });

  group('the line coming and going', () {
    test('after a reconnect it takes its place again, restarts the paths, and sees who is here now', () async {
      final r = Rig();
      final log = <String>[];
      r.call.peerJoined.listen((p) => log.add('+${p.identity}'));
      await r.call.join();
      await r.call.enableMicrophone();
      r.signal.line(RealtimeState.reconnecting);
      expect(r.call.state, CallState.reconnecting);
      r.signal.answers['media.join'] = (_) => {
            'roomId': 'room-1',
            'identity': 'me',
            'routerRtpCapabilities': g['routerRtpCapabilities'],
            'iceServers': <dynamic>[],
            'role': 'speaker',
            'peers': [
              {'identity': 'bola', 'role': 'speaker', 'producers': <dynamic>[]},
            ],
          };
      r.signal.line(RealtimeState.connected);
      await tick(20);
      expect(r.call.state, CallState.joined);
      expect(log, ['+bola']);
      expect(r.signal.methods, contains('media.restartIce'));
    });

    test('the server no longer having this person ends the call for them', () async {
      final r = Rig();
      final ended = <String>[];
      r.call.ended.listen((e) => ended.add(e.reason));
      await r.call.join();
      r.signal.line(RealtimeState.reconnecting);
      r.signal.answers['media.join'] = (_) => throw const CallException('gone', 'no_route');
      r.signal.line(RealtimeState.connected);
      await tick(20);
      expect(r.call.state, CallState.closed);
      expect(ended, ['no_route']);
    });

    test('the line closing for good ends the call', () async {
      final r = Rig();
      final ended = <String>[];
      r.call.ended.listen((e) => ended.add(e.reason));
      await r.call.join();
      r.signal.line(RealtimeState.closed);
      await tick(5);
      expect(r.call.state, CallState.closed);
      expect(ended, ['disconnected']);
    });
  });

  group('leaving', () {
    test('tells the server, lets go of the devices, closes the transports and the line', () async {
      final r = Rig();
      await r.call.join();
      final t = await r.call.enableMicrophone() as FakeTrack;
      await r.call.leave();
      expect(r.signal.methods, contains('media.leave'));
      expect(t.stopped, isTrue);
      expect(r.signal.disconnected, isTrue);
      expect(r.factory.links.every((l) => l.closed), isTrue);
      expect(r.call.state, CallState.closed);
    });

    test('leaving twice, or before joining, does nothing', () async {
      final r = Rig();
      await r.call.leave();
      await r.call.join();
      await r.call.leave();
      await r.call.leave();
      expect(r.signal.methods.where((m) => m == 'media.leave'), hasLength(1));
    });
  });

  test('stats add up what is arriving, per track', () async {
    final r = Rig(join: {'peers': [ada()]});
    await r.call.join();
    await tick();
    final stats = await r.call.stats();
    expect(stats.map((s) => s.source.name), unorderedEquals(['audio', 'video']));
  });

  group('catching up on events that never arrived', () {
    const every = Duration(milliseconds: 20);
    Map<String, dynamic> joinWith(List<Map<String, dynamic>> peers) => {'roomId': 'room-1', 'identity': 'me', 'routerRtpCapabilities': g['routerRtpCapabilities'], 'iceServers': <dynamic>[], 'role': 'speaker', 'peers': peers};

    test('finds a person and their track that the room events never told it about', () async {
      final r = Rig(resync: every);
      final log = <String>[];
      r.call.peerJoined.listen((p) => log.add('+${p.identity}'));
      r.call.tracks.listen((t) => log.add('track:${t.source.name}'));
      await r.call.join();
      r.signal.answers['media.join'] = (_) => joinWith([
            {'identity': 'ada', 'role': 'host', 'producers': [{'id': 'p-a', 'kind': 'audio', 'paused': false}]},
          ]);
      await tick(200);
      expect(log, ['+ada', 'track:audio']);
      await r.call.leave();
    });

    test('notices that someone has gone without hearing about it', () async {
      final r = Rig(join: {'peers': [ada()]}, resync: every);
      final log = <String>[];
      r.call.peerLeft.listen((p) => log.add('-$p'));
      r.call.trackEnded.listen((t) => log.add('ended:${t.source.name}'));
      await r.call.join();
      await tick(20);
      r.signal.answers['media.join'] = (_) => joinWith([]);
      await tick(200);
      expect(log..sort(), ['-ada', 'ended:audio', 'ended:video']);
      await r.call.leave();
    });

    test('stops asking once the call is left, is not ended by a question that fails, and can be turned off', () async {
      final r = Rig(resync: every);
      await r.call.join();
      r.signal.answers['media.join'] = (_) => throw const CallException('busy', 'internal');
      await tick(100);
      expect(r.call.state, CallState.joined);
      await r.call.leave();
      final asked = r.signal.methods.where((m) => m == 'media.join').length;
      await tick(120);
      expect(r.signal.methods.where((m) => m == 'media.join').length, asked);

      final off = Rig();
      await off.call.join();
      final before = off.signal.methods.where((m) => m == 'media.join').length;
      await tick(120);
      expect(off.signal.methods.where((m) => m == 'media.join').length, before);
      await off.call.leave();
    });
  });
}
