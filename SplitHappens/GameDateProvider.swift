import Foundation

enum GameDateProvider {
    static func currentDate() -> Date {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return Date()
        }

        #if DEBUG
        if let overrideDate = DebugSettings.overrideDate {
            return overrideDate
        }
        #endif
        return Date()
    }
}
