import Foundation

enum GameDateProvider {
    static func currentDate() -> Date {
        #if DEBUG
        if let overrideDate = DebugSettings.overrideDate {
            return overrideDate
        }
        #endif
        return Date()
    }
}
