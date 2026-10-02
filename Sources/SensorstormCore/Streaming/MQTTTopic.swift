import Foundation

/// Topic strings: the placeholders a user may type, and MQTT's wildcard matching.
public enum MQTTTopic {

    /// `${userId}` is Sensor Logger's spelling, so a topic copied from its documentation
    /// works unchanged; `${deviceId}` says what it actually is here. Both become the same
    /// per-install identifier the HTTP payload already carries — one phone, one topic, and
    /// several phones on one broker stay apart.
    public static func expand(_ topic: String, deviceID: String) -> String {
        topic.replacingOccurrences(of: "${userId}", with: deviceID)
            .replacingOccurrences(of: "${deviceId}", with: deviceID)
    }

    /// A comma- or line-separated field as a list, blanks dropped.
    public static func list(_ text: String?) -> [String] {
        (text ?? "")
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `+` matches one level, `#` the rest — the broker's rules, applied again on the phone
    /// because a rule names a filter and the broker only says which topic a message came on.
    public static func matches(filter: String, topic: String) -> Bool {
        let filterLevels = filter.split(separator: "/", omittingEmptySubsequences: false)
        let topicLevels = topic.split(separator: "/", omittingEmptySubsequences: false)
        for (index, level) in filterLevels.enumerated() {
            if level == "#" { return true }
            guard index < topicLevels.count else { return false }
            if level != "+", level != topicLevels[index] { return false }
        }
        return filterLevels.count == topicLevels.count
    }
}
