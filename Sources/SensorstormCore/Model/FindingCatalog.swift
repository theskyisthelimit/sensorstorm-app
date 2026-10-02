import Foundation

/// A text in several languages, as data.
///
/// A catalog is content a person might load from a file their employer wrote, so its words
/// cannot live in the app's String Catalog. The JSON form is either one plain string — taken
/// as German, the app's source language — or an object keyed by language code.
public struct LocalizedText: Codable, Sendable, Hashable {
    public var values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public init(de: String, en: String? = nil) {
        values = ["de": de]
        if let en { values["en"] = en }
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let text = try? single.decode(String.self) {
            values = ["de": text]
        } else {
            values = try single.decode([String: String].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        try single.encode(values)
    }

    /// The text in `language` (a code like `de`, `fr-CH` or `pt-BR`; only the first part
    /// counts), else English, else German, else whatever there is.
    public func resolve(_ language: String) -> String {
        let code = String(language.prefix { $0 != "-" && $0 != "_" }).lowercased()
        return values[code] ?? values["en"] ?? values["de"] ?? values.values.sorted().first ?? ""
    }

    public var isEmpty: Bool { values.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

/// One question a catalog asks about a case, beyond the label.
public struct AttributeDefinition: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case text
        case number
        /// One of ``choices``; the stored value is the choice's `key`.
        case choice
        /// Yes or no, stored as `1` and `0`.
        case flag
    }

    public struct Choice: Codable, Sendable, Hashable, Identifiable {
        public var key: String
        public var title: LocalizedText

        public var id: String { key }

        public init(key: String, title: LocalizedText) {
            self.key = key
            self.title = title
        }
    }

    /// Stable across languages and versions; what the answer is stored under.
    public var key: String
    public var title: LocalizedText
    public var kind: Kind
    public var choices: [Choice]
    public var unit: String?

    public var id: String { key }

    public init(key: String, title: LocalizedText, kind: Kind, choices: [Choice] = [], unit: String? = nil) {
        self.key = key
        self.title = title
        self.kind = kind
        self.choices = choices
        self.unit = unit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(LocalizedText.self, forKey: .title)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
    }
}

/// What can be found, with the questions to ask about each kind.
public struct CatalogEntry: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var label: LocalizedText
    public var defaultSeverity: Int?
    public var attributes: [AttributeDefinition]

    public var id: String { key }

    public init(key: String, label: LocalizedText, defaultSeverity: Int? = nil,
                attributes: [AttributeDefinition] = []) {
        self.key = key
        self.label = label
        self.defaultSeverity = defaultSeverity
        self.attributes = attributes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        label = try container.decode(LocalizedText.self, forKey: .label)
        defaultSeverity = try container.decodeIfPresent(Int.self, forKey: .defaultSeverity)
        attributes = try container.decodeIfPresent([AttributeDefinition].self, forKey: .attributes) ?? []
    }
}

public struct FindingCatalog: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: LocalizedText
    public var entries: [CatalogEntry]

    public init(id: String, name: LocalizedText, entries: [CatalogEntry]) {
        self.id = id
        self.name = name
        self.entries = entries
    }

    public func entry(_ key: String) -> CatalogEntry? {
        entries.first { $0.key == key }
    }

    /// The key a case stores which entry it is, next to the attribute answers.
    public static let entryAttribute = "_entry"

    public enum CatalogError: Error, Equatable, LocalizedError {
        case empty
        case duplicateKey(String)
        case severityOutOfRange(String)
        case choiceWithoutOptions(String)
        case notReadable

        public var errorDescription: String? {
            switch self {
            case .empty: String(localized: "Der Katalog hat keinen Eintrag.")
            case .duplicateKey(let key): String(localized: "Der Schlüssel „\(key)“ kommt doppelt vor.")
            case .severityOutOfRange(let key): String(localized: "Der Schweregrad von „\(key)“ liegt nicht zwischen 1 und 10.")
            case .choiceWithoutOptions(let key): String(localized: "Die Auswahl „\(key)“ hat keine Möglichkeiten.")
            case .notReadable: String(localized: "Die Datei ist kein Katalog.")
            }
        }
    }

    /// Reads and checks a catalog from JSON. A file with a typo in it is refused whole rather
    /// than half-used: a catalog that quietly drops an entry is a list somebody stops trusting.
    public static func decode(_ data: Data) throws -> FindingCatalog {
        guard let catalog = try? JSONDecoder().decode(FindingCatalog.self, from: data) else {
            throw CatalogError.notReadable
        }
        try catalog.validate()
        return catalog
    }

    public func validate() throws {
        guard !id.isEmpty, !entries.isEmpty else { throw CatalogError.empty }
        var seen = Set<String>()
        for entry in entries {
            guard seen.insert(entry.key).inserted else { throw CatalogError.duplicateKey(entry.key) }
            if let severity = entry.defaultSeverity, !GroundFinding.severityRange.contains(severity) {
                throw CatalogError.severityOutOfRange(entry.key)
            }
            var attributeKeys = Set<String>()
            for attribute in entry.attributes {
                guard attributeKeys.insert(attribute.key).inserted else {
                    throw CatalogError.duplicateKey("\(entry.key).\(attribute.key)")
                }
                if attribute.kind == .choice, attribute.choices.isEmpty {
                    throw CatalogError.choiceWithoutOptions("\(entry.key).\(attribute.key)")
                }
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: - What a case says

    /// „Belag: Asphalt · Breite: 4 mm" in `language`, for a list or a report.
    public func describe(_ attributes: [String: String], entryKey: String?, language: String) -> [(title: String, value: String)] {
        guard let entryKey, let entry = entry(entryKey) else { return [] }
        return entry.attributes.compactMap { definition in
            guard let raw = attributes[definition.key], !raw.isEmpty else { return nil }
            let value: String
            switch definition.kind {
            case .choice:
                value = definition.choices.first { $0.key == raw }?.title.resolve(language) ?? raw
            case .flag:
                value = raw == "1" ? "✓" : "—"
            case .number, .text:
                value = definition.unit.map { "\(raw) \($0)" } ?? raw
            }
            return (definition.title.resolve(language), value)
        }
    }
}

// MARK: - Built-in catalogs

extension FindingCatalog {
    /// German and English; every other language gets the English words. These are working
    /// vocabularies, not interface text — a depot in Ticino will load its own file.
    public static let builtIn: [FindingCatalog] = [road, building, green, furniture]

    private static func choice(_ key: String, _ de: String, _ en: String) -> AttributeDefinition.Choice {
        .init(key: key, title: LocalizedText(de: de, en: en))
    }

    private static func pick(_ key: String, _ de: String, _ en: String,
                             _ choices: [AttributeDefinition.Choice]) -> AttributeDefinition {
        AttributeDefinition(key: key, title: LocalizedText(de: de, en: en), kind: .choice, choices: choices)
    }

    private static func number(_ key: String, _ de: String, _ en: String, unit: String) -> AttributeDefinition {
        AttributeDefinition(key: key, title: LocalizedText(de: de, en: en), kind: .number, unit: unit)
    }

    private static func text(_ key: String, _ de: String, _ en: String) -> AttributeDefinition {
        AttributeDefinition(key: key, title: LocalizedText(de: de, en: en), kind: .text)
    }

    private static var surface: AttributeDefinition {
        pick("surface", "Belag", "Surface", [
            choice("asphalt", "Asphalt", "Asphalt"), choice("concrete", "Beton", "Concrete"),
            choice("paving", "Pflaster", "Paving"), choice("gravel", "Kies", "Gravel"),
        ])
    }

    private static var position: AttributeDefinition {
        pick("position", "Lage", "Position", [
            choice("carriageway", "Fahrbahn", "Carriageway"), choice("edge", "Rand", "Edge"),
            choice("footway", "Trottoir", "Footway"), choice("cycleway", "Radweg", "Cycleway"),
        ])
    }

    public static let road = FindingCatalog(
        id: "ch.sensorstorm.road",
        name: LocalizedText(de: "Strassenzustand", en: "Road condition"),
        entries: [
            CatalogEntry(key: "pothole", label: LocalizedText(de: "Schlagloch", en: "Pothole"),
                         defaultSeverity: 7, attributes: [surface, position]),
            CatalogEntry(key: "crack", label: LocalizedText(de: "Riss", en: "Crack"), defaultSeverity: 4,
                         attributes: [pick("crack_type", "Art", "Type", [
                            choice("longitudinal", "Längsriss", "Longitudinal"),
                            choice("transverse", "Querriss", "Transverse"),
                            choice("alligator", "Netzriss", "Alligator"),
                            choice("edge", "Randriss", "Edge"),
                         ]), number("width", "Breite", "Width", unit: "mm"), surface]),
            CatalogEntry(key: "rutting", label: LocalizedText(de: "Spurrinne", en: "Rutting"),
                         defaultSeverity: 5, attributes: [number("depth", "Tiefe", "Depth", unit: "mm")]),
            CatalogEntry(key: "edge_drop", label: LocalizedText(de: "Randabsenkung", en: "Edge drop"),
                         defaultSeverity: 5, attributes: [position]),
            CatalogEntry(key: "patch", label: LocalizedText(de: "Mangelhafte Flickstelle", en: "Poor patch"),
                         defaultSeverity: 3, attributes: [surface]),
            CatalogEntry(key: "manhole", label: LocalizedText(de: "Schachtdeckel", en: "Manhole cover"),
                         defaultSeverity: 6, attributes: [pick("state", "Zustand", "State", [
                            choice("sunken", "Abgesenkt", "Sunken"), choice("raised", "Erhöht", "Raised"),
                            choice("missing", "Fehlt", "Missing"), choice("rattling", "Klappert", "Rattling"),
                         ])]),
            CatalogEntry(key: "drain", label: LocalizedText(de: "Strassenablauf", en: "Gully"),
                         defaultSeverity: 4, attributes: [pick("state", "Zustand", "State", [
                            choice("blocked", "Verstopft", "Blocked"), choice("damaged", "Beschädigt", "Damaged"),
                         ])]),
            CatalogEntry(key: "marking", label: LocalizedText(de: "Markierung verblasst", en: "Marking faded"),
                         defaultSeverity: 3),
            CatalogEntry(key: "sign", label: LocalizedText(de: "Signal beschädigt", en: "Sign damaged"),
                         defaultSeverity: 4, attributes: [text("sign_type", "Signal", "Sign")]),
            CatalogEntry(key: "kerb", label: LocalizedText(de: "Randstein", en: "Kerb"), defaultSeverity: 3),
            CatalogEntry(key: "debris", label: LocalizedText(de: "Verschmutzung, Hindernis", en: "Debris, obstacle"),
                         defaultSeverity: 5),
        ])

    public static let building = FindingCatalog(
        id: "ch.sensorstorm.building",
        name: LocalizedText(de: "Gebäude und Fassade", en: "Building and facade"),
        entries: [
            CatalogEntry(key: "crack", label: LocalizedText(de: "Riss", en: "Crack"), defaultSeverity: 5,
                         attributes: [number("width", "Breite", "Width", unit: "mm"),
                                      pick("direction", "Richtung", "Direction", [
                                        choice("horizontal", "Waagrecht", "Horizontal"),
                                        choice("vertical", "Senkrecht", "Vertical"),
                                        choice("diagonal", "Schräg", "Diagonal"),
                                      ])]),
            CatalogEntry(key: "spalling", label: LocalizedText(de: "Abplatzung", en: "Spalling"), defaultSeverity: 6),
            CatalogEntry(key: "damp", label: LocalizedText(de: "Feuchtigkeit", en: "Damp"), defaultSeverity: 5),
            CatalogEntry(key: "corrosion", label: LocalizedText(de: "Korrosion", en: "Corrosion"), defaultSeverity: 5),
            CatalogEntry(key: "roof_leak", label: LocalizedText(de: "Undichtes Dach", en: "Roof leak"), defaultSeverity: 8),
            CatalogEntry(key: "window", label: LocalizedText(de: "Fenster defekt", en: "Window defect"), defaultSeverity: 4),
            CatalogEntry(key: "handrail", label: LocalizedText(de: "Handlauf lose", en: "Handrail loose"), defaultSeverity: 8),
            CatalogEntry(key: "stain", label: LocalizedText(de: "Verfärbung", en: "Staining"), defaultSeverity: 2),
        ])

    public static let green = FindingCatalog(
        id: "ch.sensorstorm.green",
        name: LocalizedText(de: "Grünflächen und Bäume", en: "Green spaces and trees"),
        entries: [
            CatalogEntry(key: "tree", label: LocalizedText(de: "Baum", en: "Tree"), defaultSeverity: 3,
                         attributes: [text("species", "Art", "Species"),
                                      number("girth", "Stammumfang", "Girth", unit: "cm"),
                                      pick("vitality", "Vitalität", "Vitality", [
                                        choice("vital", "Vital", "Vital"), choice("weak", "Geschwächt", "Weakened"),
                                        choice("dead", "Abgestorben", "Dead"),
                                      ])]),
            CatalogEntry(key: "branch", label: LocalizedText(de: "Gefährlicher Ast", en: "Dangerous branch"), defaultSeverity: 8),
            CatalogEntry(key: "root", label: LocalizedText(de: "Wurzelaufbruch", en: "Root heave"), defaultSeverity: 5),
            CatalogEntry(key: "hedge", label: LocalizedText(de: "Hecke verdeckt Sicht", en: "Hedge blocks view"), defaultSeverity: 5),
            CatalogEntry(key: "playground", label: LocalizedText(de: "Spielgerät defekt", en: "Playground equipment defect"),
                         defaultSeverity: 8),
        ])

    public static let furniture = FindingCatalog(
        id: "ch.sensorstorm.furniture",
        name: LocalizedText(de: "Beleuchtung und Mobiliar", en: "Lighting and street furniture"),
        entries: [
            CatalogEntry(key: "lamp", label: LocalizedText(de: "Leuchte defekt", en: "Lamp out"), defaultSeverity: 5,
                         attributes: [text("pole", "Mastnummer", "Pole number")]),
            CatalogEntry(key: "bench", label: LocalizedText(de: "Bank beschädigt", en: "Bench damaged"), defaultSeverity: 3),
            CatalogEntry(key: "bin", label: LocalizedText(de: "Abfallbehälter", en: "Waste bin"), defaultSeverity: 2,
                         attributes: [pick("state", "Zustand", "State", [
                            choice("full", "Voll", "Full"), choice("damaged", "Beschädigt", "Damaged"),
                         ])]),
            CatalogEntry(key: "bollard", label: LocalizedText(de: "Poller", en: "Bollard"), defaultSeverity: 3),
            CatalogEntry(key: "fountain", label: LocalizedText(de: "Brunnen", en: "Fountain"), defaultSeverity: 3),
            CatalogEntry(key: "graffiti", label: LocalizedText(de: "Graffiti", en: "Graffiti"), defaultSeverity: 2),
        ])
}
