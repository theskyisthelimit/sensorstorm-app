import CoreImage
import Foundation
import UIKit
import Vision

/// Blurs faces and number plates in a photo, for the copy that leaves the phone.
///
/// A street survey photographs people and cars without meaning to: a pothole with a mother
/// and a pram next to it, a sign with a van parked in front. Handing those pictures to a
/// client, a contractor or a web map is a data-protection question the person holding the
/// phone should not have to answer one photo at a time. Switched on, every photo that goes
/// into an export or a report passes through here; the originals on the phone stay as they
/// are.
///
/// Faces come from Vision's detector. Plates come from Vision's text recogniser and a set
/// of patterns (Switzerland, Germany, Austria, France, Italy, Spain, Britain) — a plate in
/// a country not listed, or too small to read, is not found, and the setting says so.
enum PhotoAnonymizer {

    enum AnonymizeError: Error {
        case unreadable
        case encodingFailed
    }

    private static let platePatterns: [NSRegularExpression] = [
        #"^[A-Z]{2}\d{1,6}$"#,                    // CH: ZH 123456
        #"^[A-Z]{1,3}[A-Z]{1,2}\d{1,4}[EH]?$"#,   // D, A: B AB 1234
        #"^[A-Z]{2}\d{3}[A-Z]{2}$"#,              // F, I: AB 123 CD
        #"^[A-Z]{2}\d{2}[A-Z]{3}$"#,              // GB: AB12 CDE
        #"^\d{4}[A-Z]{3}$"#,                      // E: 1234 ABC
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func looksLikePlate(_ text: String) -> Bool {
        let cleaned = text.uppercased().filter { $0.isLetter || $0.isNumber }
        guard (4...9).contains(cleaned.count) else { return false }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        return platePatterns.contains { $0.firstMatch(in: cleaned, range: range) != nil }
    }

    /// Rectangles (normalised, origin at the lower left, as Vision reports them) that should
    /// be hidden.
    static func regions(in image: CIImage) -> [CGRect] {
        var found: [CGRect] = []
        let handler = VNImageRequestHandler(ciImage: image, options: [:])

        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        try? handler.perform([faces, text])

        found += (faces.results ?? []).map(\.boundingBox)
        for observation in text.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, looksLikePlate(candidate.string) else { continue }
            found.append(observation.boundingBox)
        }
        return found
    }

    /// Writes a copy of `source` with the regions pixelated.
    static func anonymise(_ source: URL, to destination: URL) throws {
        guard let original = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
            throw AnonymizeError.unreadable
        }
        let extent = original.extent
        var result = original

        for region in regions(in: original) {
            // Padded: a face box hugs the face, a blurred box should cover the hair and chin.
            let box = CGRect(x: region.minX * extent.width + extent.minX,
                             y: region.minY * extent.height + extent.minY,
                             width: region.width * extent.width,
                             height: region.height * extent.height)
                .insetBy(dx: -region.width * extent.width * 0.2, dy: -region.height * extent.height * 0.2)
                .intersection(extent)
            guard !box.isNull, box.width > 1, box.height > 1 else { continue }

            // Pixelation, not a Gaussian blur: a blur of a face is reversible by eye at small
            // sizes and the block size here is a fixed fraction of the region.
            let block = max(min(box.width, box.height) / 8, 6)
            let pixelated = original.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: block,
                kCIInputCenterKey: CIVector(x: box.midX, y: box.midY),
            ]).cropped(to: box)
            result = pixelated.composited(over: result)
        }

        let context = CIContext()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: result, colorSpace: colorSpace,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]) else {
            throw AnonymizeError.encodingFailed
        }
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination, options: .atomic)
    }
}
