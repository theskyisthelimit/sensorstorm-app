import Foundation

/// Zips a directory using `NSFileCoordinator`'s `.forUploading` option — the one zip
/// implementation that ships with the system, so the app carries no archiving dependency.
public enum ZipPackager {
    public static func zip(directory: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: [.forUploading],
            error: &coordinatorError
        ) { temporaryZipURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: temporaryZipURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
    }
}
