import Flutter
import UIKit
import UserNotifications

/// Connects the Dart API to the iOS library.
public class ZapiackPushPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
    private let channel: FlutterMethodChannel
    /// The tap that opened the app, kept until Dart asks for it, because Dart is not listening yet when the app starts.
    private var initialTap: Tap?
    private var dartIsReady = false

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.zapiack.push", binaryMessenger: registrar.messenger())
        let instance = ZapiackPushPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
        UNUserNotificationCenter.current().delegate = instance
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "configure":
            guard let key = args["appKey"] as? String, key.hasPrefix("pk_") else {
                return result(FlutterError(code: "invalid_key", message: "The app key must start with pk_", details: nil))
            }
            guard let group = args["appGroup"] as? String, !group.isEmpty else {
                return result(FlutterError(code: "invalid_group", message: "On iOS, appGroup is required: it is how the app and its notification extension share what they need", details: nil))
            }
            let base = (args["baseUrl"] as? String).flatMap(URL.init(string:)) ?? SharedState.defaultBaseUrl
            ZapiackPush.shared.configure(appKey: key, appGroup: group, baseUrl: base)
            result(nil)
        case "requestPermission":
            Task { result(await ZapiackPush.shared.requestPermission()) }
        case "installationId":
            result(ZapiackPush.shared.installationId)
        case "login":
            guard let id = args["userId"] as? String else { return result(FlutterError(code: "invalid_argument", message: "userId is required", details: nil)) }
            ZapiackPush.shared.login(id)
            result(nil)
        case "logout":
            ZapiackPush.shared.logout()
            result(nil)
        case "addTags":
            ZapiackPush.shared.addTags(Self.values(args["tags"]))
            result(nil)
        case "removeTags":
            ZapiackPush.shared.removeTags(args["keys"] as? [String] ?? [])
            result(nil)
        case "screen":
            guard let name = args["name"] as? String else { return result(FlutterError(code: "invalid_argument", message: "name is required", details: nil)) }
            ZapiackPush.shared.screen(name)
            result(nil)
        case "track":
            guard let name = args["name"] as? String else { return result(FlutterError(code: "invalid_argument", message: "name is required", details: nil)) }
            result(ZapiackPush.shared.track(name, properties: Self.values(args["properties"])))
        case "flush":
            Task { await ZapiackPush.shared.flush(); result(nil) }
        case "initialTap":
            dartIsReady = true
            result(initialTap.map(Self.map))
            initialTap = nil
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Push address

    public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ZapiackPush.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    // MARK: Taps and notifications in front

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let tap = ZapiackPush.shared.handle(response) {
            if dartIsReady { channel.invokeMethod("tap", arguments: Self.map(tap)) } else { initialTap = tap }
        }
        completionHandler()
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show it even when the app is open: the person asked for notifications.
        if #available(iOS 14.0, *) { completionHandler([.banner, .list, .sound, .badge]) } else { completionHandler([.alert, .sound, .badge]) }
    }

    // MARK: Helpers

    private static func values(_ raw: Any?) -> [String: JSONValue] {
        guard let dict = raw as? [String: Any] else { return [:] }
        return dict.mapValues(json)
    }

    private static func json(_ value: Any) -> JSONValue {
        switch value {
        case let v as Bool: return .bool(v)
        case let v as NSNumber: return .number(v.doubleValue)
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map(json))
        case let v as [String: Any]: return .object(v.mapValues(json))
        default: return .null
        }
    }

    private static func map(_ tap: Tap) -> [String: Any?] {
        [
            "messageId": tap.messageId,
            "deliveryId": tap.deliveryId,
            "sessionId": tap.sessionId,
            "actionId": tap.actionId,
            "event": tap.event,
            "link": tap.link?.absoluteString,
        ]
    }
}
