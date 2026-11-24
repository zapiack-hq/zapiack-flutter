// What a call needs from the phone besides the connection: the microphone, the camera, the screen and the speaker. Behind an
// interface so a call can be tested without a phone; `webrtc_adapter.dart` has the real one.
library;

import 'mediasoup/link.dart';

abstract class CallMedia {
  Future<MediaTrack> microphone();

  /// The front camera when [front] is true, otherwise the back one.
  Future<MediaTrack> camera({required bool front});

  /// Asks the person to share their screen.
  Future<MediaTrack> screen();
  Future<void> setSpeaker(bool on);
  Future<void> switchCamera(MediaTrack track);

  /// A stream, in the engine's own type, holding [track]: what a video view is given to show it.
  Future<Object> streamOf(MediaTrack track);
}
