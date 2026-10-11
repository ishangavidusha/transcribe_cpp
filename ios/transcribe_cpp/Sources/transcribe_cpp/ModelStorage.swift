import Flutter
import Foundation

/// Where downloaded models live, and how much room is left for them.
///
/// Application Support, not Documents, Caches or tmp. Documents is backed up to
/// iCloud, and Apple rejects apps that back up content they can download again.
/// Caches and tmp are purged under storage pressure, so a 300 MB model would
/// silently vanish between launches and be downloaded again.
///
/// The directory is flagged excluded from backup on every call rather than once.
/// Apple documents that some file operations reset the flag to false, so
/// setting it on each use is what keeps it true. Flagging the directory covers
/// everything inside it.
enum ModelStorage {
    static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var dir = base.appendingPathComponent("transcribe_cpp/models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        return dir
    }

    /// Bytes available for a download the user asked for.
    ///
    /// The "important usage" figure counts space iOS would free by purging
    /// caches for a user-initiated task, which a model download is. The plain
    /// available-capacity figure leaves that out and reports a phone as fuller
    /// than it is.
    static func freeBytes() throws -> Int64 {
        let values = try directory().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            switch call.method {
            case "modelDirectory":
                result(try directory().path)
            case "freeBytes":
                result(NSNumber(value: try freeBytes()))
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch {
            result(FlutterError(
                code: "storage_failed",
                message: error.localizedDescription,
                details: nil
            ))
        }
    }
}
