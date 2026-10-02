import Foundation

/// A stream that is not one of the device's own sensors: a Bluetooth thermometer, the
/// round-trip time to a router, a number that arrived on an MQTT topic.
///
/// ``SensorID`` is a closed list — its raw values are file names that must never change,
/// and a stream that only exists because somebody carried a RuuviTag into the room cannot
/// be on it. Those go here instead. The file format is the same `.ssbin`, so scrubbing,
/// decimation and every exporter's reader work on them unchanged; only the identity
/// differs: a string that stays stable across recordings, and a title the person can read.
public struct ExternalStreamInfo: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable, Hashable, CaseIterable {
        case bluetooth
        case network
        case mqtt
        case beacon
        case nearby
        case nfc
        case homeKit
        case accessory
        case derived
        case health
        case device
    }

    /// Stable across recordings: `ble.<device>.<decoder>`, `net.rtt.<host>`, `mqtt.<topic>`.
    /// The same device in two recordings is the same stream.
    public var id: String
    public var source: Source
    /// What the person reads: „RuuviTag 4F2A · Temperatur“.
    public var title: String
    public var channels: [String]
    public var channelUnits: [String]
    public var sampleCount: Int
    public var effectiveRateHz: Double

    public init(id: String, source: Source, title: String, channels: [String],
                channelUnits: [String]? = nil, sampleCount: Int = 0, effectiveRateHz: Double = 0) {
        self.id = id
        self.source = source
        self.title = title
        self.channels = channels
        self.channelUnits = channelUnits ?? Array(repeating: "", count: channels.count)
        self.sampleCount = sampleCount
        self.effectiveRateHz = effectiveRateHz
    }

    public var channelCount: Int { channels.count }

    public func unit(forChannel index: Int) -> String {
        channelUnits.indices.contains(index) ? channelUnits[index] : ""
    }

    /// `ext-<readable part>-<hash>.ssbin`. The readable part is for the person who opens the
    /// folder; the hash is what keeps two ids that slug to the same text apart.
    public var fileName: String { Self.fileName(for: id) }

    public static func fileName(for id: String) -> String {
        "ext-\(slug(id))-\(hash(id)).ssbin"
    }

    /// Lower-case letters and digits, everything else one dash, at most 40 characters — a
    /// file name every file system takes.
    public static func slug(_ id: String) -> String {
        var out = ""
        var lastWasDash = true
        for scalar in id.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(40))
    }

    /// FNV-1a over the UTF-8 bytes, eight hex digits. Not a security property — only a
    /// name that is the same on every run and every device.
    static func hash(_ text: String) -> String {
        var value: UInt32 = 0x811C9DC5
        for byte in text.utf8 {
            value ^= UInt32(byte)
            value = value &* 16_777_619
        }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }
}

/// Decides which stream a set of named values belongs to.
///
/// A decoder file may return `{ temperature }` today and `{ temperature, humidity }` after
/// a firmware update, and a stream is a table of fixed width. The first set of names becomes
/// the stream; a different set becomes a second stream next to it (`base#2`) instead of a
/// broken file or a silently dropped column.
public struct ExternalStreamRegistry: Sendable {
    public struct Variant: Sendable, Hashable {
        public let id: String
        /// Channel order of this stream — values are written in it.
        public let fields: [String]
    }

    private var variants: [String: [Variant]] = [:]

    public init() {}

    public mutating func resolve(base: String, fields: [String]) -> Variant {
        let wanted = Set(fields)
        if let match = variants[base]?.first(where: { Set($0.fields) == wanted }) {
            return match
        }
        let count = variants[base]?.count ?? 0
        let variant = Variant(id: count == 0 ? base : "\(base)#\(count + 1)", fields: fields)
        variants[base, default: []].append(variant)
        return variant
    }

    /// The values of `named` in the stream's own channel order; a field the packet did not
    /// carry is `NaN`, which is how the format says „not measured".
    public static func values(_ named: [String: Double], in variant: Variant) -> [Double] {
        variant.fields.map { named[$0] ?? .nan }
    }
}
