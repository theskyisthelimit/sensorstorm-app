import Foundation

/// The magic packet that wakes a sleeping machine: six bytes of 0xFF and then the hardware
/// address sixteen times.
///
/// iOS cannot read a device's hardware address, so it has to be typed once and is kept with
/// the host. Sending is the part iOS makes hard — see the network tools for what it needs.
public enum WakeOnLAN {

    /// „aa:bb:cc:dd:ee:ff", with `-`, `.` or nothing between the pairs. `nil` for anything
    /// that is not exactly six bytes of hex.
    public static func parseMAC(_ text: String) -> [UInt8]? {
        let digits = text.filter { !":-. ".contains($0) }
        guard digits.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        for _ in 0..<6 {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    public static func format(_ mac: [UInt8]) -> String {
        mac.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// 102 bytes.
    public static func magicPacket(mac: [UInt8]) -> Data? {
        guard mac.count == 6 else { return nil }
        var data = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { data.append(contentsOf: mac) }
        return data
    }
}
