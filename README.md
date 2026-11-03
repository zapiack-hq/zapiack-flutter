# zapiack

Push notifications for Flutter with Zapiack. Registers the device, shows pushes with pictures and buttons, reports taps, and follows
what the person does next, so you can see which pushes bring people back.

Android 5.0+ and iOS 15+.

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

## Maintaining

The iOS code in this package is copied from the iOS library: run `tool/sync-ios.sh` after changing it.
