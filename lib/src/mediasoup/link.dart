// The small surface of a WebRTC engine this client needs. The mediasoup logic is written against these, not against a plugin, so it
// runs (and is tested) without a phone; `webrtc_adapter.dart` is the one place that talks to flutter_webrtc.
library;

import 'ortc.dart';

/// A camera, microphone or screen track, or one that arrives from the server.
abstract class MediaTrack {
  String get id;

  /// `audio` or `video`.
  String get kind;
  bool get enabled;
  set enabled(bool value);

  /// Stops it for good and lets go of the device (the camera light goes off).
  Future<void> stop();

  /// The engine's own object, handed back to the app to show or play.
  Object get native;

  /// Called when the track ends by itself: a screen share stopped from the system, or a camera taken by another app.
  set onEnded(void Function()? fn);
}

abstract class LinkTransceiver {
  String get mid;
  Future<void> setDirection(String direction);
  Future<void> stop();
  Future<void> replaceTrack(MediaTrack? track);

  /// The track a received section brings.
  MediaTrack? get receiverTrack;
  Future<List<Json>> getStats();
}

abstract class PeerLink {
  Future<String> createOffer({bool iceRestart = false});
  Future<String> createAnswer();
  Future<void> setLocalDescription(String type, String sdp);
  Future<void> setRemoteDescription(String type, String sdp);
  Future<String?> localSdp();

  /// Adds a section that sends [track], in the stream [streamId], capped at [maxBitrate] bits per second.
  Future<LinkTransceiver> addSendTransceiver(MediaTrack track, {required String streamId, int? maxBitrate});

  /// The section with this mid, once it exists.
  Future<LinkTransceiver?> transceiverByMid(String mid);
  Future<List<Json>> getStats();
  Future<void> close();

  /// `new`, `connecting`, `connected`, `disconnected`, `failed` or `closed`.
  set onConnectionState(void Function(String state)? fn);
}

/// Makes peer connections. [iceServers] are `{urls, username, credential}`.
abstract class LinkFactory {
  PeerLink create({required List<Json> iceServers, required String iceTransportPolicy});

  /// An offer with an audio and a video section and no tracks, from which the engine's own codecs are read.
  Future<String> nativeOffer();
}
