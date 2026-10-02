import Foundation

/// A case as a message to another system — a ticketing tool, a municipal defect reporter, a
/// webhook of the person's own.
///
/// Two shapes, because two things are on the other end. A **webhook** is whatever a team set up
/// to receive JSON (Zapier, Node-RED, a chat channel, their own service), and gets one stable
/// document. **Open311 GeoReport v2** is what a good part of the world's city defect reporters
/// speak — „SeeClickFix", „Mängelmelder", the Swiss „Züri wie neu" family — and gets a form
/// post with the fields that standard defines.
public enum RemoteReport {

    // MARK: - Webhook

    public static let webhookSchema = "sensorstorm.finding.v1"

    /// The JSON for one case. Everything a receiver needs to act without calling back: where,
    /// how bad, what it is, in what state, and the cover photo if asked for.
    public static func webhookJSON(_ finding: GroundFinding, in survey: Survey, event: String = "finding",
                                   coverPhoto: Data? = nil, now: Date = Date()) -> Data {
        let lv95 = finding.location.lv95
        var object: [String: Any] = [
            "schema": webhookSchema,
            "event": event,
            "sentAt": TrackExporter.iso8601(now),
            "survey": ["id": survey.id.uuidString, "name": survey.name],
            "finding": findingObject(finding, lv95: (lv95.east, lv95.north)),
        ]
        if let coverPhoto {
            object["photo"] = ["mediaType": "image/jpeg", "base64": coverPhoto.base64EncodedString()]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    private static func findingObject(_ finding: GroundFinding, lv95: (Double, Double)) -> [String: Any] {
        var object: [String: Any] = [
            "id": finding.id.uuidString,
            "capturedAt": TrackExporter.iso8601(finding.capturedAt),
            "label": finding.label,
            "note": finding.note,
            "severity": finding.severity,
            "status": finding.status.rawValue,
            "latitude": finding.location.latitude,
            "longitude": finding.location.longitude,
            "lv95East": (lv95.0 * 100).rounded() / 100,
            "lv95North": (lv95.1 * 100).rounded() / 100,
            "photoCount": finding.photos.count,
            "videoCount": finding.videos.count,
        ]
        if finding.location.horizontalAccuracy > 0 { object["horizontalAccuracy"] = finding.location.horizontalAccuracy }
        if let address = finding.address, !address.singleLine.isEmpty {
            object["address"] = address.singleLine
            if let egid = address.egid { object["egid"] = egid }
        }
        if !finding.attributes.isEmpty { object["attributes"] = finding.attributes }
        if let area = finding.area, area.isValid { object["areaSquareMetres"] = (area.squareMetres * 10).rounded() / 10 }
        if !finding.measurements.isEmpty {
            object["measurements"] = finding.measurements.map { ["kind": $0.kind.rawValue, "value": $0.value, "unit": $0.unit] as [String: Any] }
        }
        if let volume = finding.volumeCubicMetres { object["volumeCubicMetres"] = volume }
        return object
    }

    // MARK: - Open311

    /// The fields of `POST /requests.json`.
    ///
    /// `description` carries the label and the note, because a city's form has one free-text
    /// field and putting the label only in a custom attribute would leave a clerk reading an
    /// empty description. The address is sent when there is one; coordinates always.
    public static func open311Fields(_ finding: GroundFinding, serviceCode: String, apiKey: String,
                                     jurisdiction: String?, includesPhotoURL: URL? = nil) -> [(name: String, value: String)] {
        var fields: [(String, String)] = [
            ("api_key", apiKey),
            ("service_code", serviceCode),
            ("lat", String(format: "%.7f", finding.location.latitude)),
            ("long", String(format: "%.7f", finding.location.longitude)),
            ("description", description(for: finding)),
        ]
        if let jurisdiction, !jurisdiction.isEmpty { fields.append(("jurisdiction_id", jurisdiction)) }
        if let address = finding.address, !address.singleLine.isEmpty {
            fields.append(("address_string", address.singleLine))
        }
        if let url = includesPhotoURL { fields.append(("media_url", url.absoluteString)) }
        return fields
    }

    public static func description(for finding: GroundFinding) -> String {
        [finding.label, finding.note].filter { !$0.isEmpty }.joined(separator: "\n")
            + (finding.label.isEmpty && finding.note.isEmpty ? "(\(finding.severity)/10)" : "")
    }

    /// `application/x-www-form-urlencoded`, with the characters that form encoding reserves
    /// escaped — a note with an ampersand in it must not start a new field.
    public static func formBody(_ fields: [(name: String, value: String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func escape(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        return Data(fields.map { "\(escape($0.name))=\(escape($0.value))" }.joined(separator: "&").utf8)
    }

    /// The service request id from a successful answer: the first `service_request_id`, or the
    /// `token` a city issues first when the id comes later.
    public static func parseOpen311Response(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let first = (json as? [[String: Any]])?.first ?? (json as? [String: Any])
        if let id = first?["service_request_id"] as? String, !id.isEmpty { return id }
        if let id = first?["service_request_id"] as? Int { return String(id) }
        return first?["token"] as? String
    }
}
