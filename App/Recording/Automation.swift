import Foundation
import SensorstormCore
import UserNotifications

/// Rules live apart from ``RecordingSettings``: editing one must not restart the sensors,
/// which every change to the settings blob that affects capture does.
@MainActor
enum RuleStore {
    private static let key = "rules"

    static func load() -> [Rule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else { return [] }
        return rules
    }

    static func save(_ rules: [Rule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// One line in the rules console: a rule that fired, or a message that arrived.
struct RuleLogEntry: Identifiable, Sendable {
    enum Kind: Sendable { case notification, annotation, stop, message }

    let id = UUID()
    let date: Date
    let kind: Kind
    let title: String
    let detail: String

    var symbol: String {
        switch kind {
        case .notification: "bell.badge"
        case .annotation: "flag"
        case .stop: "stop.circle"
        case .message: "dot.radiowaves.up.forward"
        }
    }
}

/// Banners while the app is open, too. Without a delegate iOS files a notification from a
/// foreground app silently into the notification centre — and a rule that fires while the
/// record screen is up is exactly the one someone is waiting to see.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// The user's decoder files, copied into the app so they survive the original being moved.
enum DecoderLibrary {
    static var directory: URL {
        let url = URL.applicationSupportDirectory.appendingPathComponent("Decoders", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "js" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Checked before it is kept: a file that does not load is refused at the door rather
    /// than failing quietly on every scan.
    static func add(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: source, encoding: .utf8)
        _ = try ScriptDecoders(source: text)
        let name = source.deletingPathExtension().lastPathComponent + ".js"
        try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    static func load() -> [ScriptDecoders] {
        files().compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? ScriptDecoders(source: $0) }
        }
    }

    /// Shown in the app and copied on request, so the format never needs a website.
    static let example = """
        // Sensorstorm decoder file. Any number of decoder({...}) calls per file.
        // bytes: service data if serviceUuid is set, otherwise the manufacturer data
        // including its two company-ID bytes. Return { name: number, ... } or null.
        decoder({
          name: "RuuviTag (example)",
          manufacturerId: 0x0499,
          decode: function (bytes) {
            if (bytes[2] !== 5) return null;
            var t = (bytes[3] << 8) | bytes[4];
            if (t > 32767) t -= 65536;
            return { temperature: t * 0.005, humidity: ((bytes[5] << 8) | bytes[6]) * 0.0025 };
          }
        });
        decoder({
          name: "My beacon",
          namePrefix: "BEACON",
          serviceUuid: "FFF0",
          decode: function (bytes) { return { value: bytes[0] }; }
        });
        """
}
