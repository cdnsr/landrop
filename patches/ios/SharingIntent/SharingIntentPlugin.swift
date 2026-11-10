//  SharingIntentPlugin.swift
//  Replacement for flutter_sharing_intent 1.1.1 inside the LANDrop host app.
//
//  Why this exists: the original plugin has an asymmetric handoff. On a cold
//  launch it only stores the payload in `initialSharing` and never replays it to
//  the event stream; on a warm launch it only pushes to the event stream and
//  never fills `initialSharing`. If the Dart side reads through the other path,
//  or if it has not subscribed yet, the payload is dropped without any error and
//  the app comes to the foreground with nothing selected.
//
//  This implementation keeps the same channel names, the same JSON shape and the
//  same mangled symbols that the already-compiled Runner links against, but makes
//  the handoff deterministic:
//
//  1. The extension writes the payload plus a timestamp into the App Group.
//  2. This plugin picks it up on launch, on registration, when the stream starts
//     listening, and whenever the app becomes active — so the handoff no longer
//     depends on the launch URL being delivered at the right moment.
//  3. Each payload is delivered exactly once, then removed from the suite.
//  4. Every step is logged into the same file the extension writes, so a failure
//     is visible instead of silent.
//
//  ABI note: Runner references the mangled symbol
//  `_$s22flutter_sharing_intent31SwiftFlutterSharingIntentPluginC8instanceACvau`
//  and the ObjC class `FlutterSharingIntentPlugin`. The module name, the class
//  names and the `instance` static property must therefore stay identical.

import Flutter
import Foundation
import UIKit

private let kSchemePrefix = "SharingMedia"
private let kUserDefaultsKey = "SharingKey"
private let kTimestampKey = "SharingTimestamp"
private let kEventsChannelMedia = "flutter_sharing_intent/events-sharing"
private let kMethodChannel = "flutter_sharing_intent"
private let kLogFileName = "landrop-share.log"
private let kFallbackBundleId = "app.landrop.landrop-flutter"

/// ObjC entry point. GeneratedPluginRegistrant calls
/// `+[FlutterSharingIntentPlugin registerWithRegistrar:]`.
@objc(FlutterSharingIntentPlugin)
public class FlutterSharingIntentPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        SwiftFlutterSharingIntentPlugin.register(with: registrar)
    }
}

public class SwiftFlutterSharingIntentPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    /// Runner's AppDelegate reads this directly; the mangled symbol must match.
    public static let instance = SwiftFlutterSharingIntentPlugin()

    private var initialSharing: String?
    private var latestSharing: String?
    private var eventSink: FlutterEventSink?
    private var appGroupId: String = ""
    /// Timestamp of the share this process has already handed over.
    private var deliveredStamp: Double = -1
    /// True when the current share went out through the event stream.
    private var deliveredToStream = false

    public override init() {
        super.init()
        appGroupId = SwiftFlutterSharingIntentPlugin.resolveAppGroupId()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        // A share can also arrive while the app sits in the background; try the
        // foreground request again as soon as the app comes back.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil)
    }

    private static func resolveAppGroupId() -> String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
           !configured.isEmpty, !configured.hasPrefix("$(") {
            return configured
        }
        return "group." + (Bundle.main.bundleIdentifier ?? kFallbackBundleId)
    }

    // MARK: - Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: kMethodChannel, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)

        let events = FlutterEventChannel(
            name: kEventsChannelMedia, binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)

        registrar.addApplicationDelegate(instance)

        // The extension has usually written the payload before the engine
        // finished booting, so look for it immediately.
        instance.deliverPending(preferEventSink: false, reason: "registration")
        instance.requestForegroundIfNeeded()
    }

    /// A share can spawn Runner in the background without ever activating it:
    /// the system creates the process, hands over the URL, and leaves the app
    /// behind the share sheet. Asking to open our own sharing URL brings the app
    /// forward the same way a user tap would.
    private func requestForegroundIfNeeded() {
        guard UIApplication.shared.applicationState != .active else { return }
        guard let pending = UserDefaults(suiteName: appGroupId)?.double(forKey: kTimestampKey),
              pending > 0 else { return }

        let bundleId = Bundle.main.bundleIdentifier ?? kFallbackBundleId
        guard let url = URL(string: "\(kSchemePrefix)-\(bundleId)://dataUrl=\(kUserDefaultsKey)#media") else {
            return
        }
        log("app not active with a pending share; requesting foreground")
        UIApplication.shared.open(url, options: [:]) { success in
            self.log("foreground request finished (success=\(success))")
        }
    }

    // MARK: - Method channel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getInitialSharing":
            deliverPending(preferEventSink: false, reason: "getInitialSharing")
            // Only hand the payload over if the stream did not already take it;
            // the two paths are alternatives, not a fan-out.
            let payload = deliveredToStream ? nil : initialSharing
            initialSharing = nil
            latestSharing = nil
            log("getInitialSharing -> \(payload.map { "\($0.count) chars" } ?? "nil")"
                + " (stream=\(deliveredToStream))")
            // Dart is demonstrably alive at this point, so the share is now
            // safely in its hands and can be cleared for the next one.
            if payload != nil { consume() }
            result(payload)

        case "reset":
            initialSharing = nil
            latestSharing = nil
            result(nil)

        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Event channel

    public func onListen(withArguments arguments: Any?,
                         eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        guard let name = arguments as? String, name == "sharing" || name == "text" else {
            return FlutterError(code: "NO_SUCH_ARGUMENT",
                                message: "No such argument \(String(describing: arguments))",
                                details: nil)
        }
        eventSink = events

        // A payload held for getInitialSharing goes out now that a listener
        // exists; the original plugin left it stranded here.
        if let pending = initialSharing {
            initialSharing = nil
            latestSharing = pending
            deliveredToStream = true
            events(pending)
            consume()
            log("stream listener attached; replayed held payload (\(pending.count) chars)")
        } else {
            deliverPending(preferEventSink: true, reason: "onListen")
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        // The listener going away does not mean the payload was consumed.
        deliveredToStream = false
        return nil
    }

    // MARK: - App lifecycle

    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any] = [:]) -> Bool {
        if let url = launchOptions[UIApplication.LaunchOptionsKey.url] as? URL {
            _ = handleUrl(url, setInitialData: true)
            return true
        }
        if let activities = launchOptions[UIApplication.LaunchOptionsKey.userActivityDictionary]
            as? [AnyHashable: Any] {
            for value in activities.values {
                if let activity = value as? NSUserActivity,
                   let url = activity.webpageURL,
                   handleUrl(url, setInitialData: true) {
                    return true
                }
            }
        }
        deliverPending(preferEventSink: false, reason: "didFinishLaunching")
        return true
    }

    public func application(_ application: UIApplication, open url: URL,
                            options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        handleUrl(url, setInitialData: false)
    }

    public func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                            restorationHandler: @escaping ([Any]) -> Void) -> Bool {
        guard let url = userActivity.webpageURL else { return false }
        return handleUrl(url, setInitialData: true)
    }

    @objc private func applicationDidBecomeActive() {
        // The share sheet can foreground the app before any Dart code is ready.
        // This is the last chance to hand the payload over.
        deliverPending(preferEventSink: true, reason: "didBecomeActive")
        log("app became active")
    }

    @objc private func applicationWillEnterForeground() {
        // Coming back from the background: hand over anything still pending.
        // Do not request the foreground here, the app is already on its way.
        deliverPending(preferEventSink: true, reason: "willEnterForeground")
    }

    // MARK: - URL handling

    @discardableResult
    private func handleUrl(_ url: URL, setInitialData: Bool) -> Bool {
        let bundleId = Bundle.main.bundleIdentifier ?? kFallbackBundleId
        guard url.absoluteString.hasPrefix("\(kSchemePrefix)-\(bundleId)") else { return false }

        // The URL only acts as a trigger. The payload itself always comes from
        // the App Group, which the extension wrote before opening us.
        log("url received (fragment=\(url.fragment ?? "-"), initial=\(setInitialData))")
        deliverPending(preferEventSink: !setInitialData, reason: "url")
        return true
    }

    // MARK: - Pending payload

    /// Reads the payload the extension left in the App Group and hands it to the
    /// Dart side. The payload is deliberately NOT removed here: the process that
    /// picks it up can be torn down before Dart ever asks for it (the system
    /// spawns Runner for the URL, then kills it when the share sheet closes).
    /// It is cleared only after Dart actually consumes it, see `consume`.
    private func deliverPending(preferEventSink: Bool, reason: String) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else {
            log("\(reason): could not open suite \(appGroupId)")
            return
        }
        let stamp = defaults.double(forKey: kTimestampKey)
        guard stamp > 0 else { return }

        // Same share already handed over in this process; do not deliver twice.
        guard stamp != deliveredStamp else { return }

        guard let json = pendingJson(from: defaults) else {
            log("\(reason): payload present but undecodable; discarding")
            defaults.removeObject(forKey: kUserDefaultsKey)
            defaults.removeObject(forKey: kTimestampKey)
            return
        }

        deliveredStamp = stamp
        latestSharing = json

        if preferEventSink, let sink = eventSink {
            sink(json)
            deliveredToStream = true
            consume()
            log("\(reason): delivered \(json.count) chars to stream")
        } else {
            initialSharing = json
            log("\(reason): held \(json.count) chars for getInitialSharing")
        }
    }

    /// Drops the payload from the App Group once Dart has taken it, so a later
    /// launch cannot replay a share the user already handled.
    private func consume() {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        defaults.removeObject(forKey: kUserDefaultsKey)
        defaults.removeObject(forKey: kTimestampKey)
        defaults.synchronize()
        log("payload consumed and cleared")
    }

    /// Accepts the JSON array the extension writes, and also tolerates the
    /// legacy `[String]` shape the original plugin used for text and URLs.
    private func pendingJson(from defaults: UserDefaults) -> String? {
        if let data = defaults.object(forKey: kUserDefaultsKey) as? Data {
            return mediaJson(from: data)
        }
        if let list = defaults.object(forKey: kUserDefaultsKey) as? [String] {
            let joined = list.joined(separator: ",")
            guard !joined.isEmpty else { return nil }
            return jsonString([["value": joined, "type": 0]])
        }
        return nil
    }

    // MARK: - Payload conversion

    /// Normalises the payload into the shape the compiled Dart model expects:
    /// `[{value, thumbnail?, duration?, type}]` with text=0, url=1, image=2,
    /// video=3, file=4. `file://` is stripped because Dart treats `value` as a
    /// filesystem path.
    private func mediaJson(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let items = object as? [[String: Any]] else { return nil }

        var result: [[String: Any]] = []
        for item in items {
            guard let rawValue = item["value"] as? String, !rawValue.isEmpty else { continue }
            var entry: [String: Any] = [
                "value": stripFileScheme(rawValue),
                "type": (item["type"] as? Int) ?? 4,
            ]
            if let thumbnail = item["thumbnail"] as? String {
                entry["thumbnail"] = stripFileScheme(thumbnail)
            }
            if let duration = item["duration"] as? Int {
                entry["duration"] = duration
            }
            result.append(entry)
        }
        guard !result.isEmpty else { return nil }
        return jsonString(result)
    }

    private func stripFileScheme(_ identifier: String) -> String {
        guard identifier.hasPrefix("file://") else { return identifier }
        return String(identifier.dropFirst("file://".count))
    }

    private func jsonString(_ items: [[String: Any]]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: []),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: - Diagnostics

    /// Host half of the share log. Both halves share one file, so a single pull
    /// shows whether the payload was written, picked up and consumed.
    private func log(_ message: String) {
        NSLog("[LANDropShareHost] %@", message)
        guard !appGroupId.isEmpty,
              let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return }
        let directory = container.appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(kLogFileName)
        guard let data = "\(Date()) [host] \(message)\n".data(using: .utf8) else { return }

        if let handle = FileHandle(forWritingAtPath: file.path) {
            handle.seekToEndOfFile()
            if handle.offsetInFile > 64 * 1024 {
                handle.closeFile()
                try? data.write(to: file)
            } else {
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: file)
        }
    }
}
