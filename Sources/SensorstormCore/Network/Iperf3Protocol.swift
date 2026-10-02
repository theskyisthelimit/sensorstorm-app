import Foundation

/// The control channel of iperf3, the throughput tool every network technician has a server
/// for. The data itself is plain bytes on a TCP stream; what has to be exactly right is the
/// conversation around it — a 37-byte cookie, one-byte states, JSON with a length in front.
///
/// Written from the protocol's published behaviour and checked here against its own framing;
/// nothing in this file has talked to a real server, and the first test against one is the
/// one that counts.
public enum Iperf3 {

    public enum State: Int8, Sendable {
        case testStart = 1
        case testRunning = 2
        case resultRequest = 3
        case testEnd = 4
        case streamBegin = 5
        case streamRunning = 6
        case streamEnd = 7
        case allStreamsEnd = 8
        case paramExchange = 9
        case createStreams = 10
        case serverTerminate = 11
        case clientTerminate = 12
        case exchangeResults = 13
        case displayResults = 14
        case iperfStart = 15
        case iperfDone = 16
        case accessDenied = -1
        case serverError = -2
    }

    public static let cookieLength = 37

    /// 36 random characters and a terminating zero, which the server expects on the control
    /// connection and on every data connection that belongs to it.
    public static func cookie(random: () -> UInt8 = { UInt8.random(in: 0...255) }) -> Data {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var bytes = (0..<(cookieLength - 1)).map { _ in alphabet[Int(random()) % alphabet.count] }
        bytes.append(0)
        return Data(bytes)
    }

    /// The test the client asks for, as the JSON the server reads in its parameter exchange.
    public static func parameters(duration: Int, parallelStreams: Int = 1, blockLength: Int = 131_072,
                                  reverse: Bool = false) -> Data {
        var object: [String: Any] = [
            "tcp": true,
            "omit": 0,
            "time": max(duration, 1),
            "parallel": max(parallelStreams, 1),
            "len": max(blockLength, 1),
            "client_version": "3.16",
        ]
        if reverse { object["reverse"] = true }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// A four-byte big-endian length and then the JSON.
    public static func frame(_ json: Data) -> Data {
        var data = Data()
        let length = UInt32(json.count)
        data.append(UInt8(length >> 24 & 0xFF)); data.append(UInt8(length >> 16 & 0xFF))
        data.append(UInt8(length >> 8 & 0xFF)); data.append(UInt8(length & 0xFF))
        data.append(json)
        return data
    }

    /// Takes one framed message off the front of `buffer`, or leaves it alone when the rest has
    /// not arrived yet. A length that cannot be right (above 1 MiB) drops the buffer: the
    /// stream is out of step and nothing after it can be trusted.
    public static func readFrame(_ buffer: inout Data) -> Data? {
        let b = [UInt8](buffer.prefix(4))
        guard b.count == 4 else { return nil }
        let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard length <= 1 << 20 else {
            buffer.removeAll()
            return nil
        }
        guard buffer.count >= 4 + length else { return nil }
        let payload = buffer.subdata(in: buffer.startIndex.advanced(by: 4)..<buffer.startIndex.advanced(by: 4 + length))
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex.advanced(by: 4 + length))
        return payload
    }

    /// Megabits per second, the unit iperf3 prints.
    public static func megabits(bytes: Int64, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }
}
