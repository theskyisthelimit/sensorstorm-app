import Foundation

/// An entry as the person fills it in, before it is a record: every field a form has, as the
/// text typed. `record()` is the one place that decides whether it is complete and what it
/// becomes, so the form and the tests agree.
public struct NFCDraft: Sendable, Equatable, Identifiable {

    public var id: String { kind.rawValue }


    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case url, text, phone, mail, sms, location, wifi, contact, bluetooth, custom
        public var id: String { rawValue }
    }

    public var kind: Kind
    public var url = ""
    public var text = ""
    public var language = "de"
    public var phone = ""
    public var mailAddress = ""
    public var mailSubject = ""
    public var mailBody = ""
    public var smsBody = ""
    public var latitude = ""
    public var longitude = ""
    public var wifiSSID = ""
    public var wifiPassword = ""
    public var wifiSecurity = WiFiCredential.Security.wpaWpa2
    public var contact = VCard()
    public var bluetoothAddress = ""
    public var bluetoothName = ""
    public var bluetoothLowEnergy = false
    public var mimeType = ""
    /// Text, or hex bytes when `customIsHex` is set.
    public var customPayload = ""
    public var customIsHex = false

    public init(kind: Kind = .url) {
        self.kind = kind
    }

    /// A decimal number with either a point or a comma, as a person types it.
    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// `nil` while something required is missing or does not parse.
    public func record() -> NDEFRecord? {
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch kind {
        case .url:
            let address = clean(url)
            guard !address.isEmpty else { return nil }
            // A bare host gets a scheme: a tag that opens nothing is the usual mistake.
            return .uri(address.contains(":") ? address : "https://" + address)
        case .text:
            let body = clean(text)
            return body.isEmpty ? nil : .text(body, language: clean(language).isEmpty ? "de" : clean(language))
        case .phone:
            let number = clean(phone)
            return number.contains(where: \.isNumber) ? .phone(number) : nil
        case .mail:
            let address = clean(mailAddress)
            return address.contains("@") ? .mail(address, subject: mailSubject, body: mailBody) : nil
        case .sms:
            let number = clean(phone)
            return number.contains(where: \.isNumber) ? .sms(number, body: smsBody) : nil
        case .location:
            guard let lat = Self.number(latitude), let lon = Self.number(longitude),
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return .geo(latitude: lat, longitude: lon)
        case .wifi:
            let name = wifiSSID
            guard !name.isEmpty, name.utf8.count <= 32 else { return nil }
            if wifiSecurity != .open, wifiPassword.isEmpty { return nil }
            return WiFiCredential(ssid: name, password: wifiPassword, security: wifiSecurity).record
        case .contact:
            let card = VCard(firstName: clean(contact.firstName), lastName: clean(contact.lastName),
                             organization: clean(contact.organization), title: clean(contact.title),
                             phone: clean(contact.phone), email: clean(contact.email),
                             website: clean(contact.website), address: clean(contact.address))
            return card.displayName.isEmpty ? nil : card.record
        case .bluetooth:
            guard let address = MACAddress(bluetoothAddress) else { return nil }
            let name = clean(bluetoothName)
            return bluetoothLowEnergy
                ? BluetoothOOB.lowEnergy(address: address, isRandom: address.isLocallyAdministered, name: name)
                : BluetoothOOB.classic(address: address, name: name)
        case .custom:
            let type = clean(mimeType)
            guard type.contains("/") else { return nil }
            if customIsHex {
                guard let bytes = HexCoding.data(customPayload) else { return nil }
                return .mime(type, payload: bytes)
            }
            return .mime(type, payload: Data(customPayload.utf8))
        }
    }

    public var isComplete: Bool { record() != nil }
}
