import Foundation
import JavaScriptCore

/// Decoders written by the user, in JavaScript, any number of them in one file.
///
/// ```js
/// decoder({
///   name: "My beacon",
///   manufacturerId: 0x0590,      // and/or serviceUuid: "FCD2", namePrefix: "ATC_"
///   decode: function (bytes, advertisement) {
///     return { temperature: ((bytes[3] << 8) | bytes[4]) / 100 };
///   }
/// });
/// decoder({ name: "Second one", serviceUuid: "181A", decode: function (bytes) { … } });
/// ```
///
/// `bytes` is the service data when the decoder names a service, otherwise the full
/// manufacturer data including the two company-identifier bytes. Every criterion given must
/// match; a decoder with none is refused, because it would claim every packet in the room.
/// What `decode` returns is read as name → number; anything else is ignored, and `null`
/// means „not mine after all".
///
/// JavaScript rather than a format of our own: a decoder is arithmetic on bytes, and a
/// declarative schema for that is a worse programming language than the one already on
/// the phone. JavaScriptCore ships with iOS, so this costs no dependency.
public final class ScriptDecoders: @unchecked Sendable {

    public struct LoadError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private struct Definition {
        let name: String
        let manufacturerID: Int?
        let serviceUUID: String?
        let namePrefix: String?
        let decode: JSValue
    }

    private let context: JSContext
    private let definitions: [Definition]
    /// JavaScriptCore serialises a context's VM itself; this keeps `lastError` coherent.
    private let lock = NSLock()

    public var names: [String] { definitions.map(\.name) }

    public init(source: String) throws {
        guard let context = JSContext() else { throw LoadError(message: "JavaScriptCore") }
        self.context = context

        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript("""
            var __decoders = [];
            function decoder(d) { __decoders.push(d); }
            """)
        context.evaluateScript(source)
        if let exception { throw LoadError(message: exception) }

        // `decoders = [...]` works too, for a file written as plain data.
        let all = context.evaluateScript("""
            __decoders.concat(typeof decoders !== "undefined" && Array.isArray(decoders) ? decoders : [])
            """)
        let count = Int(all?.objectForKeyedSubscript("length").toInt32() ?? 0)
        var found: [Definition] = []
        for index in 0 ..< count {
            guard let value = all?.atIndex(index),
                  let decode = value.objectForKeyedSubscript("decode"), decode.isObject else {
                continue
            }
            let manufacturer = value.objectForKeyedSubscript("manufacturerId")
            let service = value.objectForKeyedSubscript("serviceUuid")
            let prefix = value.objectForKeyedSubscript("namePrefix")
            let definition = Definition(
                name: value.objectForKeyedSubscript("name").flatMap { $0.isString ? $0.toString() : nil }
                    ?? "Decoder \(index + 1)",
                manufacturerID: manufacturer.flatMap { $0.isNumber ? Int($0.toInt32()) : nil },
                serviceUUID: service.flatMap { $0.isString ? Self.normalise($0.toString()) : nil },
                namePrefix: prefix.flatMap { $0.isString ? $0.toString() : nil },
                decode: decode)
            guard definition.manufacturerID != nil || definition.serviceUUID != nil
                    || definition.namePrefix != nil else {
                throw LoadError(message: String(localized: "„\(definition.name)“ nennt weder manufacturerId noch serviceUuid noch namePrefix."))
            }
            found.append(definition)
        }
        guard !found.isEmpty else {
            throw LoadError(message: String(localized: "Die Datei enthält keinen Decoder."))
        }
        definitions = found
        context.exceptionHandler = { _, _ in }
    }

    public func decode(_ advertisement: BLEAdvertisement) -> BLEReading? {
        for definition in definitions {
            guard let bytes = bytes(for: definition, in: advertisement) else { continue }
            let info: [String: Any] = ["name": advertisement.name ?? ""]
            let result = lock.withLock {
                definition.decode.call(withArguments: [bytes.map { Int($0) }, info])
            }
            guard let object = result, object.isObject,
                  let dictionary = object.toDictionary() as? [String: Any] else { continue }
            let fields = dictionary.keys.sorted().compactMap { key -> BLEReading.Field? in
                guard let number = dictionary[key] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
                return .init(key, number.doubleValue)
            }
            if !fields.isEmpty { return BLEReading(decoder: definition.name, fields: fields) }
        }
        return nil
    }

    private func bytes(for definition: Definition, in advertisement: BLEAdvertisement) -> [UInt8]? {
        if let prefix = definition.namePrefix,
           !(advertisement.name ?? "").hasPrefix(prefix) { return nil }
        if let manufacturer = definition.manufacturerID {
            guard let data = advertisement.manufacturerData, data.count >= 2,
                  Int(data[data.startIndex]) | Int(data[data.startIndex + 1]) << 8 == manufacturer else {
                return nil
            }
        }
        if let service = definition.serviceUUID {
            let match = advertisement.serviceData.first { Self.normalise($0.key) == service }
            guard let data = match?.value else { return nil }
            return [UInt8](data)
        }
        return advertisement.manufacturerData.map { [UInt8]($0) }
            ?? (definition.namePrefix != nil ? [] : nil)
    }

    /// `0000fcd2-0000-1000-8000-00805f9b34fb`, `fcd2` and `FCD2` are one service.
    static func normalise(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        if upper.count == 36, upper.hasPrefix("0000"), upper.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(upper.dropFirst(4).prefix(4))
        }
        return upper
    }
}
