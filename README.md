# zapiack

Push notifications, live messaging and voice and video calls for Flutter with Zapiack, in one package.

- **Push**: registers the device, shows pushes with pictures and buttons, reports taps, and follows what the person does next, so you can see which pushes bring people back.
- **Realtime**: chat, live updates and presence over one WebSocket.
- **Calls**: one-to-one and group audio and video, with a mediasoup client written for this SDK.

Android 7.0+ (API 24) and iOS 15+.

```yaml
dependencies:
  zapiack: ^0.1.0
```

## Use it

```dart
import 'package:zapiack/zapiack.dart';

await ZapiackPush.instance.configure(
  appKey: 'pk_…',
  appGroup: 'group.com.example.app', // iOS only: see below
);

// Ask when it makes sense for your users, for example after a tap on a button.
final allowed = await ZapiackPush.instance.requestPermission();

ZapiackPush.instance.onTap.listen((tap) {
  // tap.link, tap.actionId (the button), tap.event
});
final opened = await ZapiackPush.instance.getInitialTap(); // the push that started the app, if any
```

Link a device to your user and group devices with tags:

```dart
await ZapiackPush.instance.login('user_123');
await ZapiackPush.instance.logout();
await ZapiackPush.instance.addTags({'plan': 'pro'});
```

Follow what happens after a tap. Both are credited to the push only for a short window after it was tapped:

```dart
await ZapiackPush.instance.screen('OrderDetails');
await ZapiackPush.instance.track('purchase', properties: {'total': 49});
```

## Android

Firebase Cloud Messaging has to be set up as in any Android app (`google-services.json` and the Google services plugin). The plugin
adds its own Firebase service. If you also use another plugin that registers one, such as `firebase_messaging`, only one of them
receives a push: call `ZapiackMessagingService.handle` from yours, as described in the Android library's README.

## iOS

1. In Xcode, turn on **Push Notifications** and **Background Modes → Remote notifications** for the Runner target.
2. Add an **App Group** to the Runner target, and use its name as `appGroup`.
3. Add a **Notification Service Extension** target with the same App Group, and make its class a subclass of
   `ZapiackNotificationService` from the Zapiack iOS package (`ZapiackNotificationExtension`). The extension reports that a push
   arrived and shows its picture and buttons. Without it, pushes still show, with no arrival report, picture or buttons.

## Realtime

Live messages over one WebSocket: chat, live updates, presence, and signalling for calls. Pure Dart, no native setup; separate from push.

Your app never holds an API key. Your **server** asks Zapiack for a short-lived token for the signed-in user (the key needs the **Realtime** scope, or no scope limits), and hands it to the app:

```bash
curl -X POST https://api.zapiack.com/v1/realtime/tokens \
  -H "Authorization: Bearer $ZAPIACK_API_KEY" -H "Content-Type: application/json" \
  -d '{"userId":"user_42","capabilities":{"chat:*":["subscribe","publish","presence"]}}'
# → { "token": "eyJ…", "expiresAt": "…", "url": "wss://rt.zapiack.com/?token=eyJ…" }
```

`capabilities` says what that user may do on which channels (`*` matches anything): `subscribe`, `publish`, `presence`, `history`, `signal`. Tokens last an hour unless you ask for less (`ttlSeconds`, at most a day).

In the app:

```dart
import 'package:zapiack/zapiack.dart';

final realtime = ZapiackRealtime(
  // Ask YOUR server for a token. Called on every connect, so an expired token is replaced.
  getToken: () async => (await http.get(Uri.parse('https://your.server/realtime-token'))).body,
);
await realtime.connect();

final sub = realtime.subscribe('chat:room-1').listen((m) => print('${m.from}: ${m.data}'));
final result = await realtime.publish('chat:room-1', {'text': 'hi'}, persist: true); // completes when the server confirms

final here = realtime.presence('chat:room-1');
here.enter({'name': 'Ann'});
here.changes.listen((e) => print('${e.action} ${e.member.user}'));
realtime.signal('call-7', otherConnectionId, 'offer', {'sdp': sdp});
realtime.errors.listen((e) => print(e));
await sub.cancel(); // leaves the channel when the last listener cancels
```

- **Reconnects by itself** with a growing, jittered pause, fetches a fresh token each time, re-joins every channel and replays what it missed since the last message it saw (publish with `persist` to make a message replayable). Messages already seen are not repeated.
- **Sends made while offline** wait (up to 100) and go out in order once the line is back.
- A message that cannot be replayed because the client was away longer than the project's retention is reported as an error with code 410: reload that channel's history over REST.
- The project can refuse a client for good (Realtime switched off, or the connection was removed in the dashboard). Then `connect` fails with code 403 and it does not retry.

## Voice and video calls

One-to-one and group calls: microphone, camera (front and back), screen sharing, mute, speaker, and recovery when the phone changes network. The media protocol client is written for this SDK, so there is no mediasoup package behind it. The WebRTC engine is [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc), which this package depends on (it carries the native WebRTC library, so it adds to the size of every app that uses `zapiack`, push-only ones included).

Set `minSdk` to 24 or higher on Android and add the permissions to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
```

and on iOS, in `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key><string>Calls use the camera.</string>
<key>NSMicrophoneUsageDescription</key><string>Calls use the microphone.</string>
```

Your server makes the room and a token for each person (`POST /v1/calls/rooms` and `POST /v1/calls/tokens`, or `POST /v1/calls` to ring someone) and gives the token to the app. The app never holds your API key.

```dart
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zapiack/zapiack.dart';

final call = createZapiackCall(
  // Your server asks Zapiack for a token and returns it here. Called on every connect, so an expired one is replaced.
  getToken: () => myServer.callToken(),
);

call.tracks.listen((t) async {
  final renderer = RTCVideoRenderer();
  await renderer.initialize();
  renderer.srcObject = t.mediaStream;       // show it with RTCVideoView(renderer); audio plays by itself
});
call.trackEnded.listen((t) => remove(t.identity, t.source));
call.ended.listen((e) => closeScreen(e.reason));

await call.join();
await call.enableMicrophone();
await call.enableCamera();          // the front camera
await call.setSpeaker(true);
await call.switchCamera();          // front <-> back, without interrupting the video
await call.setMuted(TrackSource.audio, true);
await call.leave();
```

What a person may send comes from their token: a `listener` can receive but never send.

| | |
|---|---|
| `join()` | Connects and joins the room the token is for. |
| `enableMicrophone()`, `enableCamera()`, `shareScreen()` | Start sending. Each can be given your own track. |
| `setMuted(source, muted)`, `isMuted(source)` | Nothing is sent while muted, and the others are told. |
| `switchCamera()`, `setSpeaker(on)` | Front or back camera; loudspeaker or earpiece. |
| `stop(source)`, `leave()` | Stop one track (the camera light goes off) or leave. |
| `tracks`, `trackEnded`, `paused`, `peerJoined`, `peerLeft`, `ended`, `errors` | Streams of what happens in the room. |
| `stats()` | Bytes, packets, losses and jitter per received track. |
| `members`, `role`, `roomId`, `state` | Where the call stands. |

On a phone the network changes under a call (Wi-Fi to mobile data, a lift, a tunnel). The client gives a path that goes `disconnected` a few seconds to recover, then restarts it with fresh parameters from the server. If the connection to the server itself dropped, it rejoins the room and picks up who is there now.

A call does not need to be restarted if the network changes or an event is missed: the call re-asks the server who is in the room every 30 seconds (`resyncEvery`, `Duration.zero` turns it off).

**Not covered yet:** keeping a call alive in the background (iOS needs the `voip` background mode and CallKit; Android needs a foreground service), and screen sharing needs a foreground service on Android and a broadcast extension on iOS (see the `flutter_webrtc` screen sharing guide). Ringing a phone that is closed is done with push: see `POST /v1/calls`. Calls are verified on Android; iOS has not been run on a device.

## Maintaining

The iOS code in this package is copied from the iOS library: run `tool/sync-ios.sh` after changing it.

## Licence of the call code

MIT, including code derived from mediasoup-client (ISC) and sdp-transform (MIT): see `NOTICE`.
