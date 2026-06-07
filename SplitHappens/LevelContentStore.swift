import Foundation

enum LevelContentStore {
    static func loadStartupSnapshot(calendar: Calendar) -> LevelContentSnapshot {
        let start = CFAbsoluteTimeGetCurrent()
        let bundledSnapshot = LevelContentSnapshot.bundledSnapshot(calendar: calendar)

        guard let cachedDocuments = LocalLevelCache.loadCachedDocuments() else {
            let elapsedMS = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
            print("LevelContentStore: startup using bundled snapshot in \(elapsedMS)ms (no cache).")
            return bundledSnapshot
        }

        guard let cachedSnapshot = try? LevelContentSnapshot.snapshotFromVersionedDocuments(
            levelsData: cachedDocuments.levelsData,
            scheduleData: cachedDocuments.scheduleData,
            calendar: calendar
        ) else {
            let elapsedMS = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
            print("LevelContentStore: startup using bundled snapshot in \(elapsedMS)ms (cache invalid).")
            return bundledSnapshot
        }

        let selected = cachedSnapshot.version > bundledSnapshot.version ? cachedSnapshot : bundledSnapshot
        let elapsedMS = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        print("LevelContentStore: startup snapshot selected in \(elapsedMS)ms.")
        return selected
    }

    static func fetchRemoteSnapshotIfNewer(
        current: LevelContentSnapshot,
        calendar: Calendar
    ) async -> LevelContentSnapshot? {
        let start = CFAbsoluteTimeGetCurrent()
        guard let remotePayload = await RemoteLevelService.fetchValidatedSnapshot(calendar: calendar) else {
            return nil
        }

        guard remotePayload.snapshot.version > current.version else {
            return nil
        }

        LocalLevelCache.saveCachedDocuments(
            levelsData: remotePayload.levelsData,
            scheduleData: remotePayload.scheduleData
        )
        let elapsedMS = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        print("LevelContentStore: remote refresh persisted and ready in \(elapsedMS)ms.")

        return remotePayload.snapshot
    }
}
