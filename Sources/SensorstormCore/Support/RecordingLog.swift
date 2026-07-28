import Foundation
import OSLog

public enum RecordingLog {
    private static let logger = Logger(subsystem: "ch.sensorstorm.app", category: "recording")

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
