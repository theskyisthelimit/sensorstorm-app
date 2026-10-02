import SensorstormCore
import SwiftUI

extension NFCDraft.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .url: "Adresse (URL)"
        case .text: "Text"
        case .phone: "Telefonnummer"
        case .mail: "E-Mail"
        case .sms: "SMS"
        case .location: "Ort"
        case .wifi: "WLAN"
        case .contact: "Kontakt"
        case .bluetooth: "Bluetooth"
        case .custom: "Eigener Typ"
        }
    }

    var symbol: String {
        switch self {
        case .url: "link"
        case .text: "textformat"
        case .phone: "phone"
        case .mail: "envelope"
        case .sms: "message"
        case .location: "mappin.and.ellipse"
        case .wifi: "wifi"
        case .contact: "person.crop.rectangle"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .custom: "doc.badge.gearshape"
        }
    }
}

extension NDEFContent {
    /// The name of what the record is, with the schemes of the URI type told apart: a `tel:`
    /// address is a phone number to a person, whatever the format calls it.
    var title: LocalizedStringKey {
        switch self {
        case .uri(let value):
            let scheme = value.lowercased()
            if scheme.hasPrefix("tel:") { return "Telefonnummer" }
            if scheme.hasPrefix("mailto:") { return "E-Mail" }
            if scheme.hasPrefix("sms:") { return "SMS" }
            if scheme.hasPrefix("geo:") { return "Ort" }
            return "Adresse (URL)"
        case .text: return "Text"
        case .wifi: return "WLAN"
        case .contact: return "Kontakt"
        case .bluetooth: return "Bluetooth"
        case .smartPoster: return "Smart Poster"
        case .mime: return "MIME-Daten"
        case .external: return "Externer Typ"
        case .empty: return "Leer"
        case .unknown: return "Unbekannt"
        }
    }

    var symbol: String {
        switch self {
        case .uri(let value):
            let scheme = value.lowercased()
            if scheme.hasPrefix("tel:") { return "phone" }
            if scheme.hasPrefix("mailto:") { return "envelope" }
            if scheme.hasPrefix("sms:") { return "message" }
            if scheme.hasPrefix("geo:") { return "mappin.and.ellipse" }
            return "link"
        case .text: return "textformat"
        case .wifi: return "wifi"
        case .contact: return "person.crop.rectangle"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .smartPoster: return "doc.richtext"
        case .mime: return "doc"
        case .external: return "shippingbox"
        case .empty: return "circle.dashed"
        case .unknown: return "questionmark.square"
        }
    }

    /// Something the phone can open: a web page, a phone number, a mail.
    var openURL: URL? {
        switch self {
        case .uri(let value): URL(string: value)
        case .smartPoster(let uri, _): uri.flatMap { URL(string: $0) }
        default: nil
        }
    }
}

extension NFCTagInfo.Technology {
    var title: LocalizedStringKey {
        switch self {
        case .miFareUltralight: "MIFARE Ultralight oder NTAG"
        case .miFarePlus: "MIFARE Plus"
        case .miFareDESFire: "MIFARE DESFire"
        case .miFare: "MIFARE"
        case .iso7816: "ISO 7816 (Chipkarte)"
        case .felica: "FeliCa"
        case .iso15693: "ISO 15693 (Vicinity)"
        }
    }
}

extension NFCTagInfo.NDEFStatus {
    var title: LocalizedStringKey {
        switch self {
        case .notSupported: "Kein NDEF"
        case .readOnly: "Schreibgeschützt"
        case .readWrite: "Beschreibbar"
        }
    }
}

extension WiFiCredential.Security {
    var title: LocalizedStringKey {
        switch self {
        case .open: "Offen"
        case .wep: "WEP (veraltet)"
        case .wpa: "WPA"
        case .wpa2: "WPA2"
        case .wpaWpa2: "WPA und WPA2"
        }
    }
}
