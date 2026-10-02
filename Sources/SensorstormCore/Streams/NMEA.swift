import Foundation

/// NMEA 0183 from an external GNSS receiver — the kind that sits in a pole or a pocket and
/// talks over a Bluetooth serial service, with a position good to a centimetre when it has
/// a correction signal. The phone's own GPS is good to metres; for a survey of kerbs, manholes
/// or building edges that is the difference between a map and a measurement.
///
/// Receivers send their sentences in whatever pieces the radio carries: three bytes of a
/// `$GNGGA` in one notification, the rest in the next. ``NMEAReceiver`` puts the lines back
/// together, checks each one's checksum, and turns a position sentence plus whatever the
/// receiver last said about speed and accuracy into one row of a stream.
public enum NMEA {
    /// `$` … `*hh`: the XOR of every character between them must equal the two hex digits.
    /// A sentence the radio dropped a byte from fails here instead of becoming a position
    /// in the wrong country.
    public static func validatedBody(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$"), let star = trimmed.lastIndex(of: "*") else { return nil }
        let body = String(trimmed[trimmed.index(after: trimmed.startIndex)..<star])
        let given = String(trimmed[trimmed.index(after: star)...])
        guard given.count == 2, let expected = UInt8(given, radix: 16) else { return nil }
        var sum: UInt8 = 0
        for byte in body.utf8 { sum ^= byte }
        return sum == expected ? body : nil
    }

    /// `ddmm.mmmm` (or `dddmm.mmmm`) and a hemisphere letter to signed degrees.
    public static func degrees(_ field: String, hemisphere: String) -> Double? {
        guard let dot = field.firstIndex(of: "."), field.distance(from: field.startIndex, to: dot) >= 3,
              let value = Double(field) else { return nil }
        let wholeDigits = field.distance(from: field.startIndex, to: dot)
        let degreeDigits = wholeDigits - 2
        guard let degrees = Double(field.prefix(degreeDigits)) else { return nil }
        let minutes = value - degrees * 100
        guard minutes >= 0, minutes < 60 else { return nil }
        let magnitude = degrees + minutes / 60
        switch hemisphere {
        case "N", "E": return magnitude
        case "S", "W": return -magnitude
        default: return nil
        }
    }

    public static let knotsToMetresPerSecond = 0.514444

    /// Printable ASCII and line ends only. A receiver's notifications are text; a characteristic
    /// that sends binary is something else, and feeding it to the line assembler would fill the
    /// buffer with nothing.
    public static func looksLikeText(_ data: Data) -> Bool {
        !data.isEmpty && data.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0x0D || $0 == 0x0A }
    }
}

public enum NMEASentence: Sendable, Equatable {
    /// GGA: the position and how it was obtained. `quality` is the receiver's own code:
    /// 0 none, 1 GPS, 2 differential, 4 RTK fixed, 5 RTK float.
    case fix(latitude: Double, longitude: Double, altitude: Double?, quality: Int, satellites: Int,
             hdop: Double?, correctionAge: Double?)
    /// RMC: speed over ground in m/s and the course, when the receiver calls it valid.
    case motion(speed: Double, course: Double?, isValid: Bool)
    /// GST: the receiver's own estimate of its error, one standard deviation per axis in metres.
    case errors(latitude: Double?, longitude: Double?, altitude: Double?)
    /// GSA: dilution of precision.
    case dilution(pdop: Double?, hdop: Double?, vdop: Double?)

    /// `nil` for a sentence this does not read, a bad checksum, or a field that cannot be a
    /// number. Anything but a clean read is dropped — an NMEA stream is a firehose, the next
    /// sentence is a second away, and a guessed position is worse than a missing one.
    public static func parse(_ line: String) -> NMEASentence? {
        guard let body = NMEA.validatedBody(line) else { return nil }
        let fields = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let head = fields.first, head.count >= 5 else { return nil }
        let kind = String(head.suffix(3))   // GGA, from GPGGA or GNGGA

        func number(_ index: Int) -> Double? {
            guard fields.indices.contains(index), !fields[index].isEmpty else { return nil }
            return Double(fields[index])
        }
        func text(_ index: Int) -> String {
            fields.indices.contains(index) ? fields[index] : ""
        }

        switch kind {
        case "GGA":
            guard let latitude = NMEA.degrees(text(2), hemisphere: text(3)),
                  let longitude = NMEA.degrees(text(4), hemisphere: text(5)),
                  let quality = Int(text(6)) else { return nil }
            return .fix(latitude: latitude, longitude: longitude, altitude: number(9),
                        quality: quality, satellites: Int(text(7)) ?? 0, hdop: number(8),
                        correctionAge: number(13))
        case "RMC":
            guard let knots = number(7) else { return nil }
            return .motion(speed: knots * NMEA.knotsToMetresPerSecond, course: number(8),
                           isValid: text(2) == "A")
        case "GST":
            return .errors(latitude: number(6), longitude: number(7), altitude: number(8))
        case "GSA":
            guard fields.count >= 18 else { return nil }
            return .dilution(pdop: number(15), hdop: number(16), vdop: number(17))
        default:
            return nil
        }
    }
}

/// Collects the pieces a Bluetooth serial service delivers into whole lines.
public struct NMEALineAssembler: Sendable {
    private var pending = Data()
    /// A line is at most 82 characters by the standard; some receivers add vendor sentences
    /// that are longer. Anything past this without a line end is noise, not a sentence.
    private let limit = 1_024

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let slice = pending[pending.startIndex..<end]
            pending.removeSubrange(pending.startIndex...end)
            if !slice.isEmpty, let line = String(data: slice, encoding: .ascii) { lines.append(line) }
        }
        if pending.count > limit { pending.removeAll() }
        return lines
    }
}

/// A receiver reduced to the rows of one stream: one row per position sentence, with the
/// speed, course and accuracy it last reported alongside.
public struct NMEAReceiver: Sendable {
    public static let channels = ["latitude", "longitude", "altitude", "quality", "satellites",
                                  "hdop", "speed", "course", "horizontalAccuracy", "verticalAccuracy"]
    public static let units = ["°", "°", "m", "", "", "", "m/s", "°", "m", "m"]

    private var assembler = NMEALineAssembler()
    private var speed = Double.nan
    private var course = Double.nan
    private var horizontalError = Double.nan
    private var verticalError = Double.nan
    private var hdopFromGSA: Double?

    public init() {}

    /// The rows this piece of the stream completed.
    public mutating func feed(_ data: Data) -> [[Double]] {
        var rows: [[Double]] = []
        for line in assembler.feed(data) {
            guard let sentence = NMEASentence.parse(line) else { continue }
            switch sentence {
            case .fix(let latitude, let longitude, let altitude, let quality, let satellites, let hdop, _):
                // Quality 0 is "no fix": the coordinates are the last ones the receiver
                // remembers, not a measurement.
                guard quality > 0 else { continue }
                rows.append([latitude, longitude, altitude ?? .nan, Double(quality), Double(satellites),
                             hdop ?? hdopFromGSA ?? .nan, speed, course, horizontalError, verticalError])
            case .motion(let value, let heading, let isValid):
                speed = isValid ? value : .nan
                course = isValid ? (heading ?? .nan) : .nan
            case .errors(let latitude, let longitude, let altitude):
                if let latitude, let longitude {
                    horizontalError = (latitude * latitude + longitude * longitude).squareRoot()
                }
                verticalError = altitude ?? .nan
            case .dilution(_, let hdop, _):
                hdopFromGSA = hdop
            }
        }
        return rows
    }

    /// What the receiver calls the quality, for a label next to the number.
    public static func qualityName(_ code: Int) -> String {
        switch code {
        case 1: "GPS"
        case 2: "DGPS"
        case 3: "PPS"
        case 4: "RTK fixed"
        case 5: "RTK float"
        case 6: "Dead reckoning"
        default: "—"
        }
    }
}
