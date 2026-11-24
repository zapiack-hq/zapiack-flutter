// On a real engine (the Android emulator's libwebrtc): the capabilities and SDP our client reads and writes are what the engine
// itself produces and accepts.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zapiack/src/mediasoup/handler.dart';
import 'package:zapiack/src/mediasoup/sdp.dart';
import 'package:zapiack/src/webrtc_adapter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reads the capabilities out of the engine\'s own offer', (tester) async {
    final offer = await WebrtcLinkFactory().nativeOffer();
    final sdp = parseSdp(offer);
    final caps = localRtpCapabilities(sdp);
    final mimes = (caps['codecs'] as List).map((c) => (c as Map)['mimeType']).toList();
    // ignore: avoid_print
    print('NATIVE CODECS: $mimes');
    expect(mimes, contains('audio/opus'));
    expect(mimes, contains('video/VP8'));
    expect((caps['headerExtensions'] as List), isNotEmpty);
    // The engine's DTLS parameters read back.
    final dtls = extractDtlsParameters(sdp);
    expect((dtls['fingerprints'] as List).single['algorithm'], isNotEmpty);
  });
}
