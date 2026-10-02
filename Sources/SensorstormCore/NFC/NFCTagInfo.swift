import Foundation

/// What one touch of a tag told the app, apart from the message on it: the chip, its serial
/// number, how much it can hold, whether it can be written.
public struct NFCTagInfo: Sendable, Equatable {

    public enum Technology: String, Sendable, Equatable, CaseIterable {
        case miFareUltralight, miFarePlus, miFareDESFire, miFare, iso7816, felica, iso15693
    }

    /// What `queryNDEFStatus` answers.
    public enum NDEFStatus: String, Sendable, Equatable {
        case notSupported, readOnly, readWrite
    }

    public var technology: Technology
    /// The serial number: UID for ISO 14443, IDm for FeliCa, the 8-byte UID of ISO 15693.
    public var uid: Data
    public var historicalBytes: Data?
    public var applicationData: Data?
    public var systemCode: Data?
    /// ISO 15693 IC manufacturer code.
    public var manufacturerCode: UInt8?
    public var ndefStatus: NDEFStatus?
    /// Bytes a message may take on this tag.
    public var ndefCapacity: Int?
    public var message: NDEFMessage?
    public var version: NTAGVersion?
    /// The raw user memory of an Ultralight or NTAG chip, four bytes a page from page 0.
    public var memory: Data?

    public init(technology: Technology, uid: Data, historicalBytes: Data? = nil, applicationData: Data? = nil,
                systemCode: Data? = nil, manufacturerCode: UInt8? = nil, ndefStatus: NDEFStatus? = nil,
                ndefCapacity: Int? = nil, message: NDEFMessage? = nil, version: NTAGVersion? = nil,
                memory: Data? = nil) {
        self.technology = technology
        self.uid = uid
        self.historicalBytes = historicalBytes
        self.applicationData = applicationData
        self.systemCode = systemCode
        self.manufacturerCode = manufacturerCode
        self.ndefStatus = ndefStatus
        self.ndefCapacity = ndefCapacity
        self.message = message
        self.version = version
        self.memory = memory
    }

    /// The chip manufacturer, from the first byte of an ISO 14443-A serial number or from the
    /// manufacturer code of an ISO 15693 tag. `nil` for a random ID (a phone, a card that
    /// changes it on purpose) and for technologies that carry no such code.
    public var manufacturer: String? {
        switch technology {
        case .iso15693:
            return manufacturerCode.flatMap(Self.manufacturerName)
        case .miFareUltralight, .miFarePlus, .miFareDESFire, .miFare, .iso7816:
            guard let first = uid.first, first != 0x08 else { return nil }
            return Self.manufacturerName(first)
        case .felica:
            return "Sony"
        }
    }

    public var usesRandomID: Bool {
        switch technology {
        case .miFareUltralight, .miFarePlus, .miFareDESFire, .miFare, .iso7816: uid.first == 0x08
        case .iso15693, .felica: false
        }
    }

    /// The chip's name when the version answer gave one.
    public var chipModel: String? { version?.model }

    /// Bytes of the current message, for „n of m bytes used".
    public var usedBytes: Int? { message.map { $0.isBlank ? 0 : $0.byteCount } }

    public var isWritable: Bool { ndefStatus == .readWrite }

    public var serialHex: String { HexCoding.string(uid, separator: ":") }

    /// ISO/IEC 7816-6 registered manufacturer codes — the byte the chip maker's number begins with.
    public static func manufacturerName(_ code: UInt8) -> String? {
        let names: [UInt8: String] = [
            0x01: "Motorola", 0x02: "STMicroelectronics", 0x03: "Hitachi", 0x04: "NXP", 0x05: "Infineon",
            0x06: "Cylink", 0x07: "Texas Instruments", 0x08: "Fujitsu", 0x09: "Matsushita", 0x0A: "NEC",
            0x0B: "Oki", 0x0C: "Toshiba", 0x0D: "Mitsubishi", 0x0E: "Samsung", 0x0F: "Hyundai", 0x10: "LG",
            0x11: "Emosyn-EM", 0x12: "INSIDE Technology", 0x13: "ORGA", 0x14: "Sharp", 0x15: "Atmel",
            0x16: "EM Microelectronic-Marin", 0x17: "KSW Microtec", 0x18: "ZMD", 0x19: "XICOR", 0x1A: "Sony",
            0x1B: "Malaysia Microelectronic Solutions", 0x1D: "Shanghai Fudan", 0x1E: "Magellan",
            0x1F: "Melexis", 0x20: "Renesas", 0x21: "TAGSYS", 0x22: "Transcore", 0x23: "Shanghai Belling",
            0x24: "Masktech", 0x25: "Innovision Research", 0x27: "Cypak", 0x28: "Ricoh", 0x29: "ASK",
            0x2A: "Unicore", 0x2B: "Maxim", 0x2C: "Impinj",
        ]
        return names[code]
    }
}

/// The answer of an NXP Ultralight or NTAG chip to GET_VERSION (command 0x60): eight bytes that
/// say which chip it is and how big. The model decides how much memory there is to dump and
/// whether a message of a given length fits.
public struct NTAGVersion: Sendable, Equatable {
    public var vendor: UInt8
    public var productType: UInt8
    public var productSubtype: UInt8
    public var majorVersion: UInt8
    public var minorVersion: UInt8
    public var storageSize: UInt8
    public var protocolType: UInt8

    /// Eight bytes, the first of them the fixed header 0x00. `nil` for anything else.
    public init?(response: Data) {
        let b = [UInt8](response)
        guard b.count == 8, b[0] == 0x00, b[1] == 0x04 else { return nil }
        vendor = b[1]; productType = b[2]; productSubtype = b[3]; majorVersion = b[4]
        minorVersion = b[5]; storageSize = b[6]; protocolType = b[7]
    }

    /// `NTAG213`, `MIFARE Ultralight EV1 (MF0UL11)`, … or `nil` for a chip not in the table.
    public var model: String? {
        switch (productType, storageSize) {
        case (0x04, 0x0B): "NTAG210"
        case (0x04, 0x0E): "NTAG212"
        case (0x04, 0x0F): "NTAG213"
        case (0x04, 0x11): "NTAG215"
        case (0x04, 0x13): "NTAG216"
        case (0x03, 0x0B): "MIFARE Ultralight EV1 (MF0UL11)"
        case (0x03, 0x0E): "MIFARE Ultralight EV1 (MF0UL21)"
        default: nil
        }
    }

    /// Bytes of user memory.
    public var userBytes: Int? {
        switch (productType, storageSize) {
        case (0x04, 0x0B), (0x03, 0x0B): 48
        case (0x04, 0x0E), (0x03, 0x0E): 128
        case (0x04, 0x0F): 144
        case (0x04, 0x11): 504
        case (0x04, 0x13): 888
        default: nil
        }
    }

    /// Pages of four bytes, counting the header and configuration pages: what a full dump reads.
    public var totalPages: Int? {
        switch (productType, storageSize) {
        case (0x04, 0x0B), (0x03, 0x0B): 20
        case (0x04, 0x0E), (0x03, 0x0E): 41
        case (0x04, 0x0F): 45
        case (0x04, 0x11): 135
        case (0x04, 0x13): 231
        default: nil
        }
    }
}
