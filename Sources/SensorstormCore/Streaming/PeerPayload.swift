import Foundation

/// What one Sensorstorm phone sends another over Bluetooth: the sample's time on the sender's
/// host clock as a little-endian Float64, then the channels as little-endian Float32.
///
/// Float32 because a notification has to fit in one packet and an IMU channel does not have
/// more than seven significant digits to give; the time is Float64 because seconds since boot
/// do, and a Float32 timestamp is wrong by milliseconds after a day of uptime.
public enum PeerPayload {
    public static func encode(time: Double, values: [Double]) -> Data {
        var data = clock(time)
        for value in values {
            withUnsafeBytes(of: Float(value).bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ data: Data) -> (time: Double, values: [Double])? {
        guard data.count >= 8, (data.count - 8) % 4 == 0, let time = decodeClock(data) else { return nil }
        let bytes = [UInt8](data)
        var values: [Double] = []
        var offset = 8
        while offset + 4 <= bytes.count {
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            values.append(Double(Float(bitPattern: bits)))
            offset += 4
        }
        return (time, values)
    }

    /// A single Float64, as the clock characteristic answers.
    public static func clock(_ time: Double) -> Data {
        withUnsafeBytes(of: time.bitPattern.littleEndian) { Data($0) }
    }

    public static func decodeClock(_ data: Data) -> Double? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data.prefix(8))
        var bits: UInt64 = 0
        for index in 0..<8 { bits |= UInt64(bytes[index]) << UInt64(8 * index) }
        return Double(bitPattern: bits)
    }
}
