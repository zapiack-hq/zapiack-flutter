import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What was tapped, handed to the app so it can route.
@immutable
class ZapiackTap {
  const ZapiackTap({
    required this.messageId,
    required this.deliveryId,
    required this.sessionId,
    this.actionId,
    this.event,
    this.link,
  });

  factory ZapiackTap.fromMap(Map<Object?, Object?> map) => ZapiackTap(
        messageId: map['messageId'] as String,
        deliveryId: map['deliveryId'] as String,
        sessionId: map['sessionId'] as String,
        actionId: map['actionId'] as String?,
        event: map['event'] as String?,
        link: map['link'] as String?,
      );

  final String messageId;
  final String deliveryId;
  final String sessionId;

  /// The button that was tapped, when it was a button.
  final String? actionId;

  /// The event name set on the notification or the button.
  final String? event;

  /// Where the notification or the button asked to go. Only links an app can route are given.
  final String? link;

  @override
  bool operator ==(Object other) =>
      other is ZapiackTap &&
      other.messageId == messageId &&
      other.deliveryId == deliveryId &&
      other.sessionId == sessionId &&
      other.actionId == actionId &&
      other.event == event &&
      other.link == link;

  @override
  int get hashCode => Object.hash(messageId, deliveryId, sessionId, actionId, event, link);

  @override
  String toString() => 'ZapiackTap(message: $messageId, action: $actionId, link: $link)';
}

/// Thrown when the SDK is used wrongly, for example with a secret key.
class ZapiackException implements Exception {
  ZapiackException(this.message);
  final String message;

  @override
  String toString() => 'ZapiackException: $message';
}

/// Push notifications for a Flutter app: ask permission, register this install, and follow what happens after a tap.
class ZapiackPush {
  ZapiackPush._(this._channel) {
    _channel.setMethodCallHandler(_fromNative);
  }

  /// The one instance to use.
  static final ZapiackPush instance = ZapiackPush._(const MethodChannel('com.zapiack.push'));

  /// For tests: an instance that talks over a channel of your choosing.
  @visibleForTesting
  factory ZapiackPush.withChannel(MethodChannel channel) => ZapiackPush._(channel);

  final MethodChannel _channel;
  final StreamController<ZapiackTap> _taps = StreamController<ZapiackTap>.broadcast();

  Future<Object?> _fromNative(MethodCall call) async {
    if (call.method == 'tap') _taps.add(ZapiackTap.fromMap(call.arguments as Map<Object?, Object?>));
    return null;
  }

  /// Call once at start-up, before anything else.
  ///
  /// [appKey] is the public key that starts with `pk_`. On iOS, [appGroup] is the App Group shared with the notification extension
  /// (for example `group.com.example.app`); it is not used on Android.
  Future<void> configure({required String appKey, String? baseUrl, String? appGroup}) {
    if (!appKey.startsWith('pk_')) {
      throw ZapiackException('ZapiackPush needs the public app key, which starts with pk_');
    }
    return _channel.invokeMethod<void>('configure', {'appKey': appKey, 'baseUrl': baseUrl, 'appGroup': appGroup});
  }

  /// Shows the system permission prompt where there is one, registers for push, and says whether notifications are allowed.
  Future<bool> requestPermission() async => (await _channel.invokeMethod<bool>('requestPermission')) ?? false;

  /// The identifier that ties this install to the service, once [configure] has run.
  Future<String?> get installationId => _channel.invokeMethod<String>('installationId');

  /// Link this install to the user your server knows. Send to `externalUserIds` from your server to reach them.
  Future<void> login(String userId) => _channel.invokeMethod<void>('login', {'userId': userId});

  /// Unlink this install from the user, on sign-out.
  Future<void> logout() => _channel.invokeMethod<void>('logout');

  /// Add or change tags; send to `tags` from your server to reach everyone who has them.
  Future<void> addTags(Map<String, Object?> tags) => _channel.invokeMethod<void>('addTags', {'tags': tags});

  Future<void> removeTags(List<String> keys) => _channel.invokeMethod<void>('removeTags', {'keys': keys});

  /// A screen the user reached, credited to the push they tapped while its window is open.
  Future<void> screen(String name) => _channel.invokeMethod<void>('screen', {'name': name});

  /// A named goal or event, credited to the push they tapped while its window is open. Returns false when there is nothing to credit.
  Future<bool> track(String name, {Map<String, Object?>? properties}) async =>
      (await _channel.invokeMethod<bool>('track', {'name': name, 'properties': properties})) ?? false;

  /// Sends anything waiting. Call when the app comes to the foreground.
  Future<void> flush() => _channel.invokeMethod<void>('flush');

  /// Notifications tapped while the app is running.
  Stream<ZapiackTap> get onTap => _taps.stream;

  /// The notification that opened the app, if it was opened by tapping one. Returns it once.
  Future<ZapiackTap?> getInitialTap() async {
    final map = await _channel.invokeMethod<Map<Object?, Object?>>('initialTap');
    return map == null ? null : ZapiackTap.fromMap(map);
  }
}
