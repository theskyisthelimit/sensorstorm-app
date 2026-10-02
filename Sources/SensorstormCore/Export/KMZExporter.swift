import Foundation

/// A walk as a KMZ: the KML and the photos in one zip, which Google Earth, Google Maps and
/// most field apps open with the pictures in the balloons.
///
/// The `doc.kml` has to sit at the root of the archive — that is the one rule of the format,
/// and why this does not go through ``ZipPackager``, whose system zip nests a folder.
public struct KMZExporter: Sendable {
    public static let fileExtension = "kmz"
    private static let mediaFolder = "files"

    private let store: SurveyStore
    private let photoCopier: SurveyExporter.PhotoCopier?

    public init(store: SurveyStore, photoCopier: SurveyExporter.PhotoCopier? = nil) {
        self.store = store
        self.photoCopier = photoCopier
    }

    /// - Parameter includingVideo: clips can be large; photos are what a balloon shows.
    public func write(_ survey: Survey, to url: URL, includingVideo: Bool = false) throws {
        let zip = try ZipWriter(url: url)
        let kml = SurveyExporter.kml(survey, mediaPrefix: "\(Self.mediaFolder)/", embedsPhotos: true)
        try zip.add("doc.kml", Data(kml.utf8))
        var written = Set<String>()
        for finding in survey.findings {
            for item in finding.media where includingVideo || item.kind == .photo {
                guard written.insert(item.fileName).inserted,
                      let source = store.url(for: item, in: survey.id) else { continue }
                if item.kind == .photo, let photoCopier {
                    // Through a scratch file: the zip wants a file to read twice, and the copier
                    // writes one.
                    let scratch = FileManager.default.temporaryDirectory
                        .appendingPathComponent("kmz-\(UUID().uuidString)-\(item.fileName)")
                    defer { try? FileManager.default.removeItem(at: scratch) }
                    try photoCopier(source, scratch)
                    try zip.addFile("\(Self.mediaFolder)/\(item.fileName)", from: scratch)
                } else {
                    try zip.addFile("\(Self.mediaFolder)/\(item.fileName)", from: source)
                }
            }
        }
        try zip.finish()
    }
}
