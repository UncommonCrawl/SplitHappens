import Foundation

enum DebugSettings {
    #if DEBUG
    private static let overrideDateStorageKey = "split-happens.debug.override-date.v1"
    static let showDebugOutlines = false
    private static let overrideDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static var overrideDate: Date? {
        get {
            UserDefaults.standard.object(forKey: overrideDateStorageKey) as? Date
        }
        set {
            let defaults = UserDefaults.standard
            if let newValue {
                defaults.set(newValue, forKey: overrideDateStorageKey)
            } else {
                defaults.removeObject(forKey: overrideDateStorageKey)
            }
        }
    }

    static func clearOverrideDate() {
        overrideDate = nil
    }

    @discardableResult
    static func setOverrideDate(_ yyyyMMdd: String) -> Bool {
        guard let parsedDate = overrideDateFormatter.date(from: yyyyMMdd) else {
            return false
        }
        overrideDate = parsedDate
        return true
    }
    #else
    static let showDebugOutlines = false
    static let overrideDate: Date? = nil
    #endif
}
