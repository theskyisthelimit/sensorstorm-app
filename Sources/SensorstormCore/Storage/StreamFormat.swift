import Foundation

/// On-disk layout of a `.ssbin` sample stream.
///
/// ```
/// offset  size  content
/// 0       4     magic "SSTM"
/// 4       2     uint16  format version (little endian)
/// 6       2     uint16  channel count
/// 8       8     reserved, zero
/// 16      …     records
///
/// record: float64 hostTime, then `channelCount` × float64 value
/// ```
///
/// Fixed-size records mean random access is pure arithmetic — no index, no parsing — which
/// is what makes scrubbing a 30-minute 200 Hz recording feel instant.
public enum StreamFormat {
    public static let magic: [UInt8] = [0x53, 0x53, 0x54, 0x4D] // "SSTM"
    public static let version: UInt16 = 1
    public static let headerSize = 16

    public static func recordSize(channelCount: Int) -> Int {
        (channelCount + 1) * MemoryLayout<Double>.size
    }

    public static func header(channelCount: Int) -> Data {
        var data = Data(capacity: headerSize)
        data.append(contentsOf: magic)
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(channelCount).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))
        return data
    }
}

public enum StreamError: Error, LocalizedError {
    case badMagic
    case unsupportedVersion(UInt16)
    case truncated

    public var errorDescription: String? {
        switch self {
        case .badMagic: "Not a Sensorstorm stream file."
        case .unsupportedVersion(let v): "Unsupported stream format version \(v)."
        case .truncated: "Stream file is truncated."
        }
    }
}
