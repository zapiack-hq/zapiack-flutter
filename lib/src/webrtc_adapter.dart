// The only file that talks to flutter_webrtc. Everything else is written against `mediasoup/link.dart`.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'call_media.dart';
import 'mediasoup/link.dart';
import 'mediasoup/ortc.dart';

class WebrtcTrack implements MediaTrack {
  WebrtcTrack(this.track);
  final rtc.MediaStreamTrack track;

  @override
  String get id => track.id ?? '';
  @override
  String get kind => track.kind ?? '';
  @override
  bool get enabled => track.enabled;
  @override
  set enabled(bool v) => track.enabled = v;
  @override
  Future<void> stop() => track.stop();
  @override
  Object get native => track;
  @override
  set onEnded(void Function()? fn) => track.onEnded = fn == null ? null : () => fn();
}

List<Json> _stats(List<rtc.StatsReport> reports) => [
      for (final r in reports) <String, dynamic>{for (final e in r.values.entries) '${e.key}': e.value, 'id': r.id, 'type': r.type},
    ];

class WebrtcTransceiver implements LinkTransceiver {
  WebrtcTransceiver(this.t, this.pc);
  final rtc.RTCRtpTransceiver t;
  final rtc.RTCPeerConnection pc;

  @override
  String get mid => t.mid;

  @override
  Future<void> setDirection(String d) => t.setDirection(switch (d) {
        'sendonly' => rtc.TransceiverDirection.SendOnly,
        'recvonly' => rtc.TransceiverDirection.RecvOnly,
        'inactive' => rtc.TransceiverDirection.Inactive,
        _ => rtc.TransceiverDirection.SendRecv,
      });

  @override
  Future<void> stop() => t.stop();

  @override
  Future<void> replaceTrack(MediaTrack? track) => t.sender.replaceTrack(track == null ? null : (track.native as rtc.MediaStreamTrack));

  @override
  MediaTrack? get receiverTrack {
    final track = t.receiver.track;
    return track == null ? null : WebrtcTrack(track);
  }

  @override
  Future<List<Json>> getStats() async {
    // The receiver's own report comes back empty on some engines, so ask the connection, for this track.
    final track = t.receiver.track;
    var reports = _stats(await t.receiver.getStats());
    if (reports.isEmpty && track != null) reports = _stats(await pc.getStats(track));
    if (reports.isEmpty) {
      // Last resort: everything the connection reports, keeping the incoming streams of this kind.
      reports = [
        for (final r in _stats(await pc.getStats()))
          if (r['type'] == 'inbound-rtp' && ('${r['kind'] ?? r['mediaType'] ?? ''}' == (track?.kind ?? ''))) r,
      ];
    }
    return reports;
  }
}

String _state(rtc.RTCPeerConnectionState s) => switch (s) {
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew => 'new',
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting => 'connecting',
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected => 'connected',
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => 'disconnected',
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed => 'failed',
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed => 'closed',
    };

Map<String, dynamic> _config(List<Json> iceServers, String policy) => {
      'iceServers': iceServers,
      'iceTransportPolicy': policy,
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    };

const _onlyWhatWasAdded = <String, dynamic>{
  'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
  'optional': <dynamic>[],
};

class WebrtcLink implements PeerLink {
  WebrtcLink(this._iceServers, this._policy);
  final List<Json> _iceServers;
  final String _policy;
  Future<rtc.RTCPeerConnection>? _pcFuture;
  rtc.MediaStream? _stream;
  void Function(String)? _onState;
  bool _closed = false;

  Future<rtc.RTCPeerConnection> get _pc => _pcFuture ??= rtc.createPeerConnection(_config(_iceServers, _policy)).then((pc) {
        pc.onConnectionState = (s) => _onState?.call(_state(s));
        return pc;
      });

  @override
  set onConnectionState(void Function(String state)? fn) => _onState = fn;

  @override
  Future<String> createOffer({bool iceRestart = false}) async {
    final pc = await _pc;
    if (iceRestart) await pc.restartIce();
    // Without this the engine adds a receive-only audio and video section of its own to every offer, which the server's answer does not
    // have, and the engine then rejects the answer.
    return (await pc.createOffer(_onlyWhatWasAdded)).sdp ?? '';
  }

  @override
  Future<String> createAnswer() async => ((await (await _pc).createAnswer())).sdp ?? '';

  @override
  Future<void> setLocalDescription(String type, String sdp) async => (await _pc).setLocalDescription(rtc.RTCSessionDescription(sdp, type));

  @override
  Future<void> setRemoteDescription(String type, String sdp) async => (await _pc).setRemoteDescription(rtc.RTCSessionDescription(sdp, type));

  @override
  Future<String?> localSdp() async => (await (await _pc).getLocalDescription())?.sdp;

  @override
  Future<LinkTransceiver> addSendTransceiver(MediaTrack track, {required String streamId, int? maxBitrate}) async {
    final pc = await _pc;
    final stream = _stream ??= await rtc.createLocalMediaStream(streamId);
    final t = await pc.addTransceiver(
      track: track.native as rtc.MediaStreamTrack,
      kind: track.kind == 'audio' ? rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio : rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: rtc.RTCRtpTransceiverInit(
        direction: rtc.TransceiverDirection.SendOnly,
        streams: [stream],
        sendEncodings: maxBitrate == null ? null : [rtc.RTCRtpEncoding(maxBitrate: maxBitrate)],
      ),
    );
    return WebrtcTransceiver(t, pc);
  }

  @override
  Future<LinkTransceiver?> transceiverByMid(String mid) async {
    for (final t in await (await _pc).getTransceivers()) {
      if (t.mid == mid) return WebrtcTransceiver(t, await _pc);
    }
    return null;
  }

  @override
  Future<List<Json>> getStats() async => _stats(await (await _pc).getStats());

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final f = _pcFuture;
    if (f == null) return;
    final pc = await f;
    await pc.close();
    await pc.dispose();
  }
}

class WebrtcLinkFactory implements LinkFactory {
  @override
  PeerLink create({required List<Json> iceServers, required String iceTransportPolicy}) => WebrtcLink(iceServers, iceTransportPolicy);

  @override
  Future<String> nativeOffer() async {
    final pc = await rtc.createPeerConnection(_config(const [], 'all'));
    try {
      await pc.addTransceiver(kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio, init: rtc.RTCRtpTransceiverInit(direction: rtc.TransceiverDirection.RecvOnly));
      await pc.addTransceiver(kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo, init: rtc.RTCRtpTransceiverInit(direction: rtc.TransceiverDirection.RecvOnly));
      return (await pc.createOffer(_onlyWhatWasAdded)).sdp ?? '';
    } finally {
      await pc.close();
      await pc.dispose();
    }
  }
}

/// Camera, microphone, screen, speaker and a native stream for a received track, through flutter_webrtc.
class WebrtcCallMedia implements CallMedia {
  const WebrtcCallMedia();

  Future<MediaTrack> _first(Future<rtc.MediaStream> s, bool video, String missing) async {
    final stream = await s;
    final tracks = video ? stream.getVideoTracks() : stream.getAudioTracks();
    if (tracks.isEmpty) throw StateError(missing);
    return WebrtcTrack(tracks.first);
  }

  @override
  Future<MediaTrack> microphone() => _first(
        rtc.navigator.mediaDevices.getUserMedia({
          'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
          'video': false,
        }),
        false,
        'No microphone was found.',
      );

  @override
  Future<MediaTrack> camera({required bool front}) => _first(
        rtc.navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'facingMode': front ? 'user' : 'environment',
            'width': {'ideal': 1280},
            'height': {'ideal': 720},
            'frameRate': {'ideal': 30},
          },
        }),
        true,
        'No camera was found.',
      );

  @override
  Future<MediaTrack> screen() => _first(rtc.navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false}), true, 'No screen was chosen.');

  @override
  Future<void> setSpeaker(bool on) => rtc.Helper.setSpeakerphoneOn(on);

  @override
  Future<void> switchCamera(MediaTrack track) async {
    await rtc.Helper.switchCamera(track.native as rtc.MediaStreamTrack);
  }

  @override
  Future<Object> streamOf(MediaTrack track) async {
    final s = await rtc.createLocalMediaStream('zapiack-${track.id}');
    await s.addTrack(track.native as rtc.MediaStreamTrack);
    return s;
  }
}
