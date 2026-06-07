import Foundation

struct RemoteSnapshotPayload {
    let snapshot: LevelContentSnapshot
    let levelsData: Data
    let scheduleData: Data
}

enum RemoteLevelService {
    private static let defaultBaseURLString = "https://splithappens-cd66e.web.app"
    private static let levelsPath = "levels.json"
    private static let schedulePath = "daily_schedule.json"

    static func fetchValidatedSnapshot(calendar: Calendar) async -> RemoteSnapshotPayload? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let baseURL = remoteBaseURL() else {
            return nil
        }

        do {
            async let levelsDataTask = fetchData(from: baseURL.appendingPathComponent(levelsPath))
            async let scheduleDataTask = fetchData(from: baseURL.appendingPathComponent(schedulePath))

            let levelsData = try await levelsDataTask
            let scheduleData = try await scheduleDataTask
            let snapshot = try await parseSnapshotOffMain(
                levelsData: levelsData,
                scheduleData: scheduleData,
                calendar: calendar
            )

            let elapsedMS = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())
            print("RemoteLevelService: fetch+validate completed in \(elapsedMS)ms")
            return RemoteSnapshotPayload(
                snapshot: snapshot,
                levelsData: levelsData,
                scheduleData: scheduleData
            )
        } catch {
            print("RemoteLevelService: remote snapshot fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func parseSnapshotOffMain(
        levelsData: Data,
        scheduleData: Data,
        calendar: Calendar
    ) async throws -> LevelContentSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let snapshot = try LevelContentSnapshot.snapshotFromVersionedDocuments(
                        levelsData: levelsData,
                        scheduleData: scheduleData,
                        calendar: calendar
                    )
                    continuation.resume(returning: snapshot)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "RemoteLevelService",
                code: 1000,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected HTTP response for \(url.absoluteString)."]
            )
        }

        return data
    }

    private static func remoteBaseURL() -> URL? {
        let infoKey = "SPLIT_HAPPENS_REMOTE_CONTENT_BASE_URL"
        if let value = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty, let url = URL(string: trimmedValue) {
                return url
            }
        }

        return URL(string: defaultBaseURLString)
    }
}
