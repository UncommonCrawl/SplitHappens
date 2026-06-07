import Foundation

struct CachedLevelDocuments {
    let levelsData: Data
    let scheduleData: Data
}

enum LocalLevelCache {
    private static let folderName = "remote-level-cache"
    private static let levelsFilename = "levels.json"
    private static let scheduleFilename = "daily_schedule.json"

    static func loadCachedDocuments() -> CachedLevelDocuments? {
        let start = CFAbsoluteTimeGetCurrent()
        guard let levelsURL = fileURL(for: levelsFilename),
              let scheduleURL = fileURL(for: scheduleFilename),
              let levelsData = try? Data(contentsOf: levelsURL),
              let scheduleData = try? Data(contentsOf: scheduleURL) else {
            return nil
        }
        let elapsedMS = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        print("LocalLevelCache: loaded cached documents in \(elapsedMS)ms.")

        return CachedLevelDocuments(levelsData: levelsData, scheduleData: scheduleData)
    }

    static func saveCachedDocuments(levelsData: Data, scheduleData: Data) {
        let start = CFAbsoluteTimeGetCurrent()
        guard let directoryURL = cacheDirectoryURL() else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let levelsURL = directoryURL.appendingPathComponent(levelsFilename)
            let scheduleURL = directoryURL.appendingPathComponent(scheduleFilename)
            let levelsTempURL = directoryURL.appendingPathComponent("\(levelsFilename).tmp")
            let scheduleTempURL = directoryURL.appendingPathComponent("\(scheduleFilename).tmp")

            try levelsData.write(to: levelsTempURL, options: .atomic)
            try scheduleData.write(to: scheduleTempURL, options: .atomic)

            try replaceItem(at: levelsURL, with: levelsTempURL)
            try replaceItem(at: scheduleURL, with: scheduleTempURL)
            let elapsedMS = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
            print("LocalLevelCache: saved cached documents in \(elapsedMS)ms.")
        } catch {
            print("LocalLevelCache: failed to save cached documents: \(error.localizedDescription)")
        }
    }

    private static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: sourceURL)
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private static func fileURL(for filename: String) -> URL? {
        cacheDirectoryURL()?.appendingPathComponent(filename)
    }

    private static func cacheDirectoryURL() -> URL? {
        guard let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        return baseDirectory.appendingPathComponent(folderName, isDirectory: true)
    }
}
