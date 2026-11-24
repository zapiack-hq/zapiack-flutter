# Changelog

All notable changes to zapiack are listed here. Versions follow [semantic versioning](https://semver.org).

## 0.2.0

This package now depends on `flutter_webrtc` (the WebRTC engine for calls), which adds the native WebRTC library to every app that uses `zapiack`, push-only apps included. Nothing else about push or Realtime changes.

- Calls: `ZapiackCall` (`createZapiackCall`), voice and video for one-to-one and group calls on Android and iOS: microphone, camera (front and back), screen sharing, mute, speaker, and recovery when the phone changes network. The mediasoup client is written for this SDK; the WebRTC engine is `flutter_webrtc`, now a dependency of this package.
- Realtime: `ZapiackRealtime.request` asks a Zapiack service something over the connection, and `RealtimeException.reason` carries the service's word for a refusal.
- Realtime: `ZapiackRealtime` for live messages over one WebSocket (pure Dart): channels, presence, signals, resume after a dropped connection.

## 0.1.0

First release.

Push for Flutter on iOS and Android, as a thin bridge over the native libraries.
