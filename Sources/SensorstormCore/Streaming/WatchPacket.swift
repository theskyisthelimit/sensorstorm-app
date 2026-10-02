import Foundation

/// A batch of fast samples from the watch, packed as bytes rather than as one dictionary per
/// sample.
///
/// The slow streams — heart rate, wrist motion at 50 Hz — travel as small dictionaries, one per
/// sample, and that is fine at fifty a second. At 800 Hz it is not: forty thousand dictionaries
/// in a queue, each with a key, a time and an array. A batch of a second is 800 rows of four
/// numbers; as bytes it is 13 kB.
///
/// The format is written on the watch too, which does not link this package. The two have to
/// agree byte for byte, and the test against this reader is what says so.
///
/// ```
/// 0      0xB1 magic
/// 1      version (1)
/// 2      kind (see ``Kind``)
/// 3      channels per row
/// 4…11   base time, Float64 LE, seconds since 1970
/// 12…15  row count, UInt32 LE
/// 16…    rows: Float32 LE seconds after the base time, then the channels as Float32 LE
/// ```
public enum WatchPacket {
    public enum Kind: UInt8, Sendable {
        /// Acceleration of the wrist at 800 Hz, x y z in g.
        case accelerometer = 1
    }

    public struct Decoded: Sendable, Equatable {
        public var kind: Kind
        public var base: Double
        public var rows: [(time: Double, values: [Double])]

        public static func == (lhs: Decoded, rhs: Decoded) -> Bool {
            lhs.kind == rhs.kind && lhs.base == rhs.base && lhs.rows.count == rhs.rows.count
                && zip(lhs.rows, rhs.rows).allSatisfy { $0.time == $1.time && $0.values == $1.values }
        }
    }

    public static let magic: UInt8 = 0xB1

    public static func encode(kind: Kind, base: Double, rows: [(offset: Float, values: [Float])]) -> Data {
        let channels = rows.first?.values.count ?? 0
        var data = Data([magic, 1, kind.rawValue, UInt8(channels)])
        withUnsafeBytes(of: base.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(rows.count).littleEndian) { data.append(contentsOf: $0) }
        for row in rows where row.values.count == channels {
            withUnsafeBytes(of: row.offset.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            for value in row.values {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    /// `nil` for anything that is not a well-formed version-1 packet: wrong magic, a length
    /// that does not match the count, an unknown kind.
    public static func decode(_ data: Data) -> Decoded? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0] == magic, bytes[1] == 1, let kind = Kind(rawValue: bytes[2]) else {
            return nil
        }
        let channels = Int(bytes[3])
        var baseBits: UInt64 = 0
        for index in 0..<8 { baseBits |= UInt64(bytes[4 + index]) << UInt64(8 * index) }
        var count: UInt32 = 0
        for index in 0..<4 { count |= UInt32(bytes[12 + index]) << UInt32(8 * index) }
        let rowSize = 4 + 4 * channels
        guard bytes.count == 16 + Int(count) * rowSize else { return nil }

        func float(at offset: Int) -> Float {
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
        let base = Double(bitPattern: baseBits)
        var rows: [(time: Double, values: [Double])] = []
        rows.reserveCapacity(Int(count))
        for row in 0..<Int(count) {
            let start = 16 + row * rowSize
            let values = (0..<channels).map { Double(float(at: start + 4 + 4 * $0)) }
            rows.append((base + Double(float(at: start)), values))
        }
        return Decoded(kind: kind, base: base, rows: rows)
    }
}
