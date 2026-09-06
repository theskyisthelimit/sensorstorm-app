import Foundation

/// MQTT 3.1.1 packet encoding, enough to connect and publish.
///
/// Written out rather than pulled in as a dependency. The subset this app needs is CONNECT,
/// PUBLISH at QoS 0 and DISCONNECT — three packets, all of them a fixed header, a
/// variable-length integer and a few length-prefixed strings. A client library would bring
/// subscriptions, sessions, QoS 1 and 2, retained messages and a reconnection state machine,
/// none of which a one-way sensor feed uses, and would put a third party between this app
/// and the one promise it makes about where data goes.
///
/// The encoding lives here, apart from the socket, because the fiddly part is the
/// variable-length integer — seven bits per byte, high bit as "more follows" — and that is
/// exactly the sort of thing a test should pin down rather than a device.
public enum MQTTPacket {

    public enum PacketError: Error, LocalizedError {
        case payloadTooLarge

        public var errorDescription: String? {
            switch self {
            case .payloadTooLarge:
                String(localized: "Die Nachricht ist zu gross für das MQTT-Protokoll.")
            }
        }
    }

    /// MQTT's variable-length integer: seven bits of value per byte, the top bit meaning
    /// "another byte follows". Four bytes maximum, hence the 256 MB packet limit.
    static func remainingLength(_ value: Int) throws -> Data {
        guard value >= 0, value <= 268_435_455 else { throw PacketError.payloadTooLarge }
        var out = Data()
        var remaining = value
        repeat {
            var byte = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining > 0
        return out
    }

    /// A UTF-8 string with a two-byte big-endian length in front, which is how MQTT writes
    /// every string it has.
    static func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        var out = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        out.append(bytes)
        return out
    }

    public static func connect(clientID: String, username: String?, password: String?,
                               keepAliveSeconds: UInt16 = 60) throws -> Data {
        var variable = string("MQTT")
        variable.append(4)                       // protocol level: 3.1.1

        // Clean session, because there is no session to resume: this is a one-way feed and
        // a broker holding state for it would only accumulate it.
        var flags: UInt8 = 0b0000_0010
        if username != nil { flags |= 0b1000_0000 }
        if password != nil { flags |= 0b0100_0000 }
        variable.append(flags)
        variable.append(UInt8(keepAliveSeconds >> 8))
        variable.append(UInt8(keepAliveSeconds & 0xFF))

        var payload = string(clientID)
        if let username { payload.append(string(username)) }
        if let password { payload.append(string(password)) }

        var packet = Data([0x10])
        packet.append(try remainingLength(variable.count + payload.count))
        packet.append(variable)
        packet.append(payload)
        return packet
    }

    /// QoS 0: fire and forget, no packet identifier, no acknowledgement.
    ///
    /// The right level for this. A dropped reading is a gap in a live view; the recording on
    /// the device is the archive and is unaffected. QoS 1 would buy retransmission at the
    /// cost of a queue that grows whenever the broker is slower than the sensors, which on a
    /// 400 Hz stream is a way to run out of memory rather than a way to lose nothing.
    public static func publish(topic: String, payload: Data) throws -> Data {
        var variable = string(topic)
        variable.append(payload)

        var packet = Data([0x30])
        packet.append(try remainingLength(variable.count))
        packet.append(variable)
        return packet
    }

    public static let disconnect = Data([0xE0, 0x00])

    /// `true` when the broker accepted the connection. A CONNACK is four bytes; the last one
    /// is the return code, and 0 is the only good value.
    public static func isAccepted(connack: Data) -> Bool {
        connack.count >= 4 && connack[connack.startIndex] == 0x20
            && connack[connack.startIndex + 3] == 0
    }

    /// What a rejected CONNACK says, so the settings screen can show a reason rather than
    /// "it did not work".
    public static func connackMessage(_ connack: Data) -> String {
        guard connack.count >= 4 else {
            return String(localized: "Der Broker hat unerwartet geantwortet.")
        }
        switch connack[connack.startIndex + 3] {
        case 0: return String(localized: "Verbunden.")
        case 1: return String(localized: "Der Broker lehnt diese Protokollversion ab.")
        case 2: return String(localized: "Der Broker lehnt diese Client-Kennung ab.")
        case 3: return String(localized: "Der Broker ist nicht verfügbar.")
        case 4: return String(localized: "Benutzername oder Passwort stimmen nicht.")
        case 5: return String(localized: "Der Broker verweigert die Berechtigung.")
        default: return String(localized: "Der Broker hat die Verbindung abgelehnt.")
        }
    }
}
