import 'package:zapiack/src/mediasoup/link.dart';
import 'package:zapiack/src/mediasoup/ortc.dart';

class FakeTrack implements MediaTrack {
  FakeTrack(this.kind, [String? id]) : id = id ?? 'track-$kind';
  @override
  final String id;
  @override
  final String kind;
  @override
  bool enabled = true;
  bool stopped = false;
  @override
  void Function()? onEnded;
  @override
  Future<void> stop() async => stopped = true;
  @override
  Object get native => this;
}

class FakeTransceiver implements LinkTransceiver {
  FakeTransceiver(this.mid, {this.receiverTrack});
  @override
  final String mid;
  @override
  final MediaTrack? receiverTrack;
  String direction = 'sendonly';
  bool stopped = false;
  MediaTrack? replaced;
  @override
  Future<void> setDirection(String d) async => direction = d;
  @override
  Future<void> stop() async => stopped = true;
  @override
  Future<void> replaceTrack(MediaTrack? t) async => replaced = t;
  @override
  Future<List<Json>> getStats() async => [];
}

/// A peer connection that answers from a script: the offers and answers a real engine made, recorded in the golden file.
class FakeLink implements PeerLink {
  FakeLink({this.offers = const [], this.answers = const [], this.offerBySequence});
  final List<String> offers;

  /// When set, the offer is the one a real engine made for the tracks added so far, in order (`a` audio, `v` video).
  final Map<String, String>? offerBySequence;
  final StringBuffer _sequence = StringBuffer();
  final List<String> answers;
  int _o = 0, _a = 0;
  final List<({String op, String type, String sdp})> log = [];
  String? _local;
  final Map<String, FakeTransceiver> byMid = {};
  final List<FakeTransceiver> added = [];
  bool closed = false;
  @override
  void Function(String state)? onConnectionState;

  @override
  Future<String> createOffer({bool iceRestart = false}) async {
    log.add((op: 'createOffer', type: iceRestart ? 'restart' : '', sdp: ''));
    final by = offerBySequence;
    if (by != null) return by[_sequence.toString()] ?? by.values.last;
    return offers[_o < offers.length ? _o++ : offers.length - 1];
  }

  @override
  Future<String> createAnswer() async => answers[_a < answers.length ? _a++ : answers.length - 1];

  @override
  Future<void> setLocalDescription(String type, String sdp) async {
    log.add((op: 'setLocal', type: type, sdp: sdp));
    _local = sdp;
  }

  @override
  Future<void> setRemoteDescription(String type, String sdp) async => log.add((op: 'setRemote', type: type, sdp: sdp));

  @override
  Future<String?> localSdp() async => _local;

  @override
  Future<LinkTransceiver> addSendTransceiver(MediaTrack track, {required String streamId, int? maxBitrate}) async {
    _sequence.write(track.kind == 'audio' ? 'a' : 'v');
    final t = FakeTransceiver('${added.length}');
    added.add(t);
    return t;
  }

  @override
  Future<LinkTransceiver?> transceiverByMid(String mid) async => byMid[mid] ?? FakeTransceiver(mid, receiverTrack: FakeTrack('audio', 'rx-$mid'));

  @override
  Future<List<Json>> getStats() async => [];

  @override
  Future<void> close() async => closed = true;
}

class FakeFactory implements LinkFactory {
  FakeFactory({required this.native, this.offers = const [], this.answers = const [], this.offerBySequence});
  final String native;
  final Map<String, String>? offerBySequence;
  final List<String> offers;
  final List<String> answers;
  final List<FakeLink> links = [];

  @override
  PeerLink create({required List<Json> iceServers, required String iceTransportPolicy}) {
    final l = FakeLink(offers: offers, answers: answers, offerBySequence: offerBySequence);
    links.add(l);
    return l;
  }

  @override
  Future<String> nativeOffer() async => native;
}
