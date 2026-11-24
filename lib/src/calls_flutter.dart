import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'call.dart';
import 'webrtc_adapter.dart';

/// A call on the real thing: the WebRTC engine of the phone.
///
/// ```dart
/// final call = createZapiackCall(getToken: () => myServer.callToken());
/// call.tracks.listen((t) => show(t.identity, t.mediaStream));
/// await call.join();
/// await call.enableMicrophone();
/// await call.enableCamera();
/// ```
ZapiackCall createZapiackCall({required Future<String> Function() getToken, Uri? url, bool forceTcp = false, bool frontCamera = true}) =>
    ZapiackCall(getToken: getToken, url: url, forceTcp: forceTcp, frontCamera: frontCamera, factory: WebrtcLinkFactory(), media: const WebrtcCallMedia());

/// The engine's own objects for what a call hands you.
extension RemoteTrackFlutter on RemoteTrack {
  /// To give to an `RTCVideoRenderer`: `renderer.srcObject = track.mediaStream`.
  rtc.MediaStream get mediaStream => stream as rtc.MediaStream;
  rtc.MediaStreamTrack get mediaTrack => track.native as rtc.MediaStreamTrack;
}
