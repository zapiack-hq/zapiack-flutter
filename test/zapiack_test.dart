import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zapiack/zapiack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.zapiack');
  late ZapiackPush push;
  late List<MethodCall> calls;
  Object? Function(MethodCall) reply = (_) => null;

  setUp(() {
    calls = [];
    reply = (_) => null;
    push = ZapiackPush.withChannel(channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> fromNative(String method, Object? args) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(channel.name, data, (_) {});
  }

  test('configure passes the key, address and group on', () async {
    await push.configure(appKey: 'pk_abc', appGroup: 'group.example');
    expect(calls.single.method, 'configure');
    expect(calls.single.arguments, {'appKey': 'pk_abc', 'baseUrl': null, 'appGroup': 'group.example'});
  });

  test('a secret key is refused before it goes anywhere', () {
    expect(() => push.configure(appKey: 'sk_secret'), throwsA(isA<ZapiackException>()));
    expect(calls, isEmpty);
  });

  test('requestPermission says whether notifications are allowed, and false when the platform says nothing', () async {
    reply = (_) => true;
    expect(await push.requestPermission(), isTrue);
    reply = (_) => null;
    expect(await push.requestPermission(), isFalse);
  });

  test('users and tags go across as they are', () async {
    await push.login('user_1');
    await push.logout();
    await push.addTags({'plan': 'pro', 'age': 3});
    await push.removeTags(['age']);
    expect(calls.map((c) => c.method), ['login', 'logout', 'addTags', 'removeTags']);
    expect(calls[0].arguments, {'userId': 'user_1'});
    expect(calls[2].arguments, {'tags': {'plan': 'pro', 'age': 3}});
    expect(calls[3].arguments, {'keys': ['age']});
  });

  test('track returns whether anything was credited', () async {
    reply = (_) => true;
    expect(await push.track('purchase', properties: {'total': 49}), isTrue);
    expect(calls.single.arguments, {'name': 'purchase', 'properties': {'total': 49}});
    reply = (_) => null;
    expect(await push.track('late'), isFalse);
  });

  test('a tap from the platform reaches the stream', () async {
    final taps = <ZapiackTap>[];
    final sub = push.onTap.listen(taps.add);
    await fromNative('tap', {
      'messageId': 'm', 'deliveryId': 'd', 'sessionId': 's', 'actionId': 'track', 'event': 'track_clicked', 'link': 'myshop://orders/1',
    });
    await Future<void>.delayed(Duration.zero);
    expect(taps.single, const ZapiackTap(messageId: 'm', deliveryId: 'd', sessionId: 's', actionId: 'track', event: 'track_clicked', link: 'myshop://orders/1'));
    await sub.cancel();
  });

  test('the tap that opened the app is read once, and is null when there was none', () async {
    reply = (_) => {'messageId': 'm', 'deliveryId': 'd', 'sessionId': 's'};
    final tap = await push.getInitialTap();
    expect(tap?.deliveryId, 'd');
    expect(tap?.actionId, isNull);
    reply = (_) => null;
    expect(await push.getInitialTap(), isNull);
  });
}
