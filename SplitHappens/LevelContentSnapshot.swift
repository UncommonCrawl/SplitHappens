import Foundation

struct LevelContentVersion: Comparable {
    let levels: Int
    let schedule: Int

    private var minComponent: Int { min(levels, schedule) }
    private var maxComponent: Int { max(levels, schedule) }
    private var sum: Int { levels + schedule }

    static func < (lhs: LevelContentVersion, rhs: LevelContentVersion) -> Bool {
        if lhs.minComponent != rhs.minComponent {
            return lhs.minComponent < rhs.minComponent
        }
        if lhs.sum != rhs.sum {
            return lhs.sum < rhs.sum
        }
        if lhs.maxComponent != rhs.maxComponent {
            return lhs.maxComponent < rhs.maxComponent
        }
        if lhs.levels != rhs.levels {
            return lhs.levels < rhs.levels
        }
        return lhs.schedule < rhs.schedule
    }
}

struct DailySchedule {
    let entries: [Entry]
    let dateByLevelID: [String: Date]

    struct Entry {
        let date: Date
        let levelID: String
    }

    func orderedLevels(from levels: [LevelDefinition]) -> [LevelDefinition] {
        guard !entries.isEmpty else {
            return levels
        }

        var levelsByID: [String: LevelDefinition] = [:]
        for level in levels {
            levelsByID[level.id] = level
        }

        var ordered: [LevelDefinition] = []
        var includedIDs = Set<String>()

        for entry in entries {
            guard let level = levelsByID[entry.levelID], !includedIDs.contains(level.id) else {
                continue
            }
            ordered.append(level)
            includedIDs.insert(level.id)
        }

        for level in levels where !includedIDs.contains(level.id) {
            ordered.append(level)
        }

        return ordered
    }
}

struct LevelContentSnapshot {
    let levels: [LevelDefinition]
    let levelsVersion: Int
    let schedule: DailySchedule
    let scheduleVersion: Int

    var version: LevelContentVersion {
        LevelContentVersion(levels: levelsVersion, schedule: scheduleVersion)
    }

    func activeLevels(isRunningInPreviews: Bool, previewRecentLevelCount: Int) -> [LevelDefinition] {
        let active = levels.filter(\.isActive)
        let baseLevels = active.isEmpty ? levels : active
        let ordered = schedule.orderedLevels(from: baseLevels)

        guard isRunningInPreviews else {
            return ordered
        }

        let datedLevels = ordered.filter { schedule.dateByLevelID[$0.id] != nil }
        let previewLevels = datedLevels.isEmpty ? ordered : datedLevels
        return Array(previewLevels.suffix(previewRecentLevelCount))
    }

    static func bundledSnapshot(calendar: Calendar) -> LevelContentSnapshot {
        do {
            let levels = try LevelContentParser.loadBundledLevels()
            let scheduleEntries = try LevelContentParser.loadBundledScheduleEntries(calendar: calendar)
            return try validateAndBuildSnapshot(
                levels: levels,
                levelsVersion: 0,
                scheduleEntries: scheduleEntries,
                scheduleVersion: 0,
                calendar: calendar
            )
        } catch {
            print("LevelContentSnapshot: strict bundled load failed: \(error.localizedDescription)")

            do {
                let levels = try LevelContentParser.loadBundledLevels()
                let validLevelIDs = Set(levels.map(\.id))
                let scheduleEntries = try LevelContentParser.loadBundledScheduleEntriesLenient(
                    calendar: calendar,
                    validLevelIDs: validLevelIDs
                )
                return try validateAndBuildSnapshot(
                    levels: levels,
                    levelsVersion: 0,
                    scheduleEntries: scheduleEntries,
                    scheduleVersion: 0,
                    calendar: calendar
                )
            } catch {
                print("LevelContentSnapshot: lenient bundled load failed: \(error.localizedDescription)")
                return emergencyFallback(calendar: calendar)
            }
        }
    }

    static func snapshotFromVersionedDocuments(
        levelsData: Data,
        scheduleData: Data,
        calendar: Calendar
    ) throws -> LevelContentSnapshot {
        let levelsDocument = try parseVersionedLevelsDocument(levelsData)
        let scheduleDocument = try parseVersionedScheduleDocument(scheduleData, calendar: calendar)

        return try validateAndBuildSnapshot(
            levels: levelsDocument.levels,
            levelsVersion: levelsDocument.version,
            scheduleEntries: scheduleDocument.entries,
            scheduleVersion: scheduleDocument.version,
            calendar: calendar
        )
    }

    private static func validateAndBuildSnapshot(
        levels: [LevelDefinition],
        levelsVersion: Int,
        scheduleEntries: [DailySchedule.Entry],
        scheduleVersion: Int,
        calendar: Calendar
    ) throws -> LevelContentSnapshot {
        guard !levels.isEmpty else {
            throw LevelContentValidationError.emptyLevels
        }

        var seenLevelIDs = Set<String>()
        var duplicateLevelIDs = Set<String>()

        for level in levels {
            let normalizedID = level.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedID.isEmpty {
                duplicateLevelIDs.insert("<empty>")
                continue
            }
            if !seenLevelIDs.insert(normalizedID).inserted {
                duplicateLevelIDs.insert(normalizedID)
            }
        }

        if !duplicateLevelIDs.isEmpty {
            throw LevelContentValidationError.duplicateLevelIDs(Array(duplicateLevelIDs).sorted())
        }

        guard !scheduleEntries.isEmpty else {
            throw LevelContentValidationError.emptySchedule
        }

        let dateFormatter = scheduleDateFormatter(timeZone: calendar.timeZone)
        var seenScheduleDates = Set<Date>()
        var duplicateScheduleDates: [String] = []

        for entry in scheduleEntries {
            if !seenScheduleDates.insert(entry.date).inserted {
                duplicateScheduleDates.append(dateFormatter.string(from: entry.date))
            }
        }

        if !duplicateScheduleDates.isEmpty {
            throw LevelContentValidationError.duplicateScheduleDates(Array(Set(duplicateScheduleDates)).sorted())
        }

        let levelIDSet = Set(levels.map(\.id))
        let missingLevelIDs = Set(
            scheduleEntries
                .map(\.levelID)
                .filter { !levelIDSet.contains($0) }
        )

        if !missingLevelIDs.isEmpty {
            throw LevelContentValidationError.scheduleReferencesMissingLevelIDs(Array(missingLevelIDs).sorted())
        }

        let sortedEntries = scheduleEntries.sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.levelID < rhs.levelID
            }
            return lhs.date < rhs.date
        }

        var dateByLevelID: [String: Date] = [:]
        for entry in sortedEntries {
            dateByLevelID[entry.levelID] = entry.date
        }

        return LevelContentSnapshot(
            levels: levels,
            levelsVersion: levelsVersion,
            schedule: DailySchedule(entries: sortedEntries, dateByLevelID: dateByLevelID),
            scheduleVersion: scheduleVersion
        )
    }

    private static func emergencyFallback(calendar: Calendar) -> LevelContentSnapshot {
        let fallback = fallbackLevel
        let fallbackDate = calendar.startOfDay(for: Date())
        let entry = DailySchedule.Entry(date: fallbackDate, levelID: fallback.id)

        return LevelContentSnapshot(
            levels: [fallback],
            levelsVersion: 0,
            schedule: DailySchedule(entries: [entry], dateByLevelID: [fallback.id: fallbackDate]),
            scheduleVersion: 0
        )
    }

    private static func parseVersionedLevelsDocument(_ data: Data) throws -> ParsedLevelsDocument {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LevelContentValidationError.invalidLevelsDocument
        }

        guard let version = parseVersion(root["version"]) else {
            throw LevelContentValidationError.invalidLevelsVersion
        }

        guard let rawLevels = root["levels"],
              JSONSerialization.isValidJSONObject(rawLevels),
              let levelsData = try? JSONSerialization.data(withJSONObject: rawLevels) else {
            throw LevelContentValidationError.invalidLevelsDocument
        }

        let levels = try LevelContentParser.decodeLevels(fromJSONArrayData: levelsData)
        return ParsedLevelsDocument(version: version, levels: levels)
    }

    private static func parseVersionedScheduleDocument(_ data: Data, calendar: Calendar) throws -> ParsedScheduleDocument {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LevelContentValidationError.invalidScheduleDocument
        }

        guard let version = parseVersion(root["version"]) else {
            throw LevelContentValidationError.invalidScheduleVersion
        }

        let scheduleKeys = ["schedule", "entries", "daily_schedule"]
        guard let rawEntries = scheduleKeys.compactMap({ root[$0] }).first,
              JSONSerialization.isValidJSONObject(rawEntries),
              let entriesData = try? JSONSerialization.data(withJSONObject: rawEntries) else {
            throw LevelContentValidationError.invalidScheduleDocument
        }

        let entries = try LevelContentParser.decodeScheduleEntries(fromJSONArrayData: entriesData, calendar: calendar)
        return ParsedScheduleDocument(version: version, entries: entries)
    }

    private static func parseVersion(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func scheduleDateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private struct ParsedLevelsDocument {
        let version: Int
        let levels: [LevelDefinition]
    }

    private struct ParsedScheduleDocument {
        let version: Int
        let entries: [DailySchedule.Entry]
    }

    private static let fallbackLevel = LevelDefinition(
        id: "at-the-bar",
        isActive: true,
        startingWords: ["BARTENDER", "COCKTAILS", "SHAKER"],
        targetRows: [6, 5, 4, 5, 4],
        answerRows: [],
        boardShape: LevelBoardShape(
            sourceWordCount: 3,
            sourceWordLengths: [9, 9, 6],
            targetRowCount: 5,
            targetRowLengths: [6, 5, 4, 5, 4]
        ),
        criteria: ["[ROWS COMPLETED]/[TOTAL ROWS] WORDS", nil, nil],
        goldTileExpectations: [],
        goldWord: "",
        note: ""
    )
}

enum LevelContentValidationError: LocalizedError {
    case emptyLevels
    case emptySchedule
    case duplicateLevelIDs([String])
    case duplicateScheduleDates([String])
    case scheduleReferencesMissingLevelIDs([String])
    case malformedScheduleDate(String)
    case invalidScheduleLevelID
    case invalidLevelsDocument
    case invalidLevelsVersion
    case invalidScheduleDocument
    case invalidScheduleVersion

    var errorDescription: String? {
        switch self {
        case .emptyLevels:
            return "Levels payload is empty."
        case .emptySchedule:
            return "Schedule payload is empty."
        case .duplicateLevelIDs(let ids):
            return "Duplicate level IDs: \(ids.joined(separator: ", "))."
        case .duplicateScheduleDates(let dates):
            return "Duplicate schedule dates: \(dates.joined(separator: ", "))."
        case .scheduleReferencesMissingLevelIDs(let ids):
            return "Schedule references missing level IDs: \(ids.joined(separator: ", "))."
        case .malformedScheduleDate(let value):
            return "Malformed schedule date: \(value)."
        case .invalidScheduleLevelID:
            return "Schedule contains an empty level ID."
        case .invalidLevelsDocument:
            return "Invalid levels document format."
        case .invalidLevelsVersion:
            return "Levels document is missing a valid version."
        case .invalidScheduleDocument:
            return "Invalid schedule document format."
        case .invalidScheduleVersion:
            return "Schedule document is missing a valid version."
        }
    }
}

private enum LevelContentParser {
    static func loadBundledLevels() throws -> [LevelDefinition] {
        if let jsonURL = bundledResourceURL(forResource: "levels", withExtension: "json", subdirectory: "public") {
            let jsonData = try Data(contentsOf: jsonURL)
            if let root = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
               let rawLevels = root["levels"],
               JSONSerialization.isValidJSONObject(rawLevels),
               let levelsData = try? JSONSerialization.data(withJSONObject: rawLevels) {
                return try decodeLevels(fromJSONArrayData: levelsData)
            }
            return try decodeLevels(fromJSONArrayData: jsonData)
        }

        // Backward compatibility for older bundles.
        guard let jsURL = bundledResourceURL(forResource: "levels", withExtension: "js", subdirectory: "public") else {
            throw LevelContentValidationError.invalidLevelsDocument
        }

        let source = try String(contentsOf: jsURL, encoding: .utf8)
        return try decodeLevels(fromJavaScriptSource: source)
    }

    static func loadBundledScheduleEntries(calendar: Calendar) throws -> [DailySchedule.Entry] {
        guard let url = bundledResourceURL(forResource: "daily_schedule", withExtension: "json", subdirectory: "public") else {
            throw LevelContentValidationError.invalidScheduleDocument
        }

        let data = try Data(contentsOf: url)
        return try decodeScheduleEntries(fromJSONArrayData: data, calendar: calendar)
    }

    static func loadBundledScheduleEntriesLenient(
        calendar: Calendar,
        validLevelIDs: Set<String>
    ) throws -> [DailySchedule.Entry] {
        guard let url = bundledResourceURL(forResource: "daily_schedule", withExtension: "json", subdirectory: "public") else {
            throw LevelContentValidationError.invalidScheduleDocument
        }

        let data = try Data(contentsOf: url)
        return try decodeScheduleEntries(
            fromJSONArrayData: data,
            calendar: calendar,
            strict: false,
            validLevelIDs: validLevelIDs
        )
    }

    static func decodeLevels(fromJavaScriptSource source: String) throws -> [LevelDefinition] {
        let normalized = normalizeLevelSource(source)
        guard let data = normalized.data(using: .utf8) else {
            throw LevelContentValidationError.invalidLevelsDocument
        }
        return try decodeLevels(fromJSONArrayData: data)
    }

    static func decodeLevels(fromJSONArrayData data: Data) throws -> [LevelDefinition] {
        let decoded = try JSONDecoder().decode([LevelFileDefinition].self, from: data)
        return decoded.map(\.levelDefinition)
    }

    static func decodeScheduleEntries(fromJSONArrayData data: Data, calendar: Calendar) throws -> [DailySchedule.Entry] {
        try decodeScheduleEntries(fromJSONArrayData: data, calendar: calendar, strict: true, validLevelIDs: nil)
    }

    private static func decodeScheduleEntries(
        fromJSONArrayData data: Data,
        calendar: Calendar,
        strict: Bool,
        validLevelIDs: Set<String>?
    ) throws -> [DailySchedule.Entry] {
        let decoded = try JSONDecoder().decode([DailyScheduleFileDefinition].self, from: data)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var entries: [DailySchedule.Entry] = []
        for item in decoded {
            let normalizedLevelID = item.id.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !normalizedLevelID.isEmpty else {
                // Allow unscheduled placeholders (for example future dates) without failing strict loads.
                continue
            }

            if let validLevelIDs, !validLevelIDs.contains(normalizedLevelID) {
                if strict {
                    throw LevelContentValidationError.scheduleReferencesMissingLevelIDs([normalizedLevelID])
                }
                continue
            }

            guard let parsedDate = formatter.date(from: item.date) else {
                if strict {
                    throw LevelContentValidationError.malformedScheduleDate(item.date)
                }
                continue
            }

            entries.append(DailySchedule.Entry(
                date: calendar.startOfDay(for: parsedDate),
                levelID: normalizedLevelID
            ))
        }

        return entries
    }

    private static func bundledResourceURL(forResource name: String, withExtension ext: String, subdirectory: String) -> URL? {
        if let subdirectoryURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return subdirectoryURL
        }

        if let directURL = Bundle.main.url(forResource: name, withExtension: ext) {
            return directURL
        }

        guard let bundle = CFBundleGetMainBundle(),
              let resourceURL = CFBundleCopyResourceURL(
                bundle,
                name as CFString,
                ext as CFString,
                subdirectory as CFString
              ) else {
            guard let bundle = CFBundleGetMainBundle(),
                  let fallbackURL = CFBundleCopyResourceURL(
                    bundle,
                    name as CFString,
                    ext as CFString,
                    nil
                  ) else {
                return nil
            }
            return fallbackURL as URL
        }

        return resourceURL as URL
    }

    private static func normalizeLevelSource(_ source: String) -> String {
        var normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("export const levels =") {
            normalized.removeFirst("export const levels =".count)
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix(";") {
            normalized.removeLast()
        }
        return quoteJavaScriptObjectKeys(in: normalized)
    }

    private static func quoteJavaScriptObjectKeys(in source: String) -> String {
        var output = ""
        var index = source.startIndex
        var insideString = false
        var stringDelimiter: Character = "\""
        var escaped = false

        while index < source.endIndex {
            let character = source[index]

            if insideString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == stringDelimiter {
                    insideString = false
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" || character == "'" {
                insideString = true
                stringDelimiter = character
                output.append(character)
                index = source.index(after: index)
                continue
            }

            if isIdentifierStart(character) {
                let tokenStart = index
                var tokenEnd = source.index(after: tokenStart)
                while tokenEnd < source.endIndex, isIdentifierBody(source[tokenEnd]) {
                    tokenEnd = source.index(after: tokenEnd)
                }

                var lookahead = tokenEnd
                while lookahead < source.endIndex, source[lookahead].isWhitespace {
                    lookahead = source.index(after: lookahead)
                }

                if lookahead < source.endIndex, source[lookahead] == ":" {
                    output.append("\"")
                    output.append(contentsOf: source[tokenStart..<tokenEnd])
                    output.append("\"")
                } else {
                    output.append(contentsOf: source[tokenStart..<tokenEnd])
                }

                index = tokenEnd
                continue
            }

            output.append(character)
            index = source.index(after: index)
        }

        return output
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        return (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122) ||
            scalar.value == 95
    }

    private static func isIdentifierBody(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        return isIdentifierStart(character) ||
            (scalar.value >= 48 && scalar.value <= 57)
    }
}

private struct LevelFileDefinition: Decodable {
    let id: String
    let active: Bool?
    let startingWords: [String]?
    let targetRows: [Int]?
    let sourceWordCount: Int?
    let sourceWordLengths: [Int]?
    let targetRowCount: Int?
    let targetRowLengths: [Int]?
    let criteria2: String?
    let source: [String]?
    let answers: [String]?
    let goldWord: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case active = "ACTIVE"
        case startingWords = "STARTING_WORDS"
        case targetRows = "TARGET_ROWS"
        case sourceWordCount = "SOURCE_WORD_COUNT"
        case sourceWordLengths = "SOURCE_WORD_LENGTHS"
        case targetRowCount = "TARGET_ROW_COUNT"
        case targetRowLengths = "TARGET_ROW_LENGTHS"
        case criteria2 = "CRITERIA_2"
        case source
        case answers
        case goldWord = "GOLD_WORD"
        case note = "NOTE"
    }

    var levelDefinition: LevelDefinition {
        let resolvedAnswers = answers ?? []
        let resolvedStartingWords = source ?? startingWords ?? []
        let resolvedAnswerRows = resolvedAnswers.map { answer in
            answer.filter { $0 != "*" }.uppercased()
        }

        let fallbackSourceLengths = resolvedStartingWords.map(\.count)
        let fallbackTargetLengths = resolvedAnswerRows.map(\.count)
        let resolvedSourceWordLengths = sourceWordLengths ?? fallbackSourceLengths
        let resolvedTargetRows = fallbackTargetLengths.isEmpty
            ? (targetRowLengths ?? targetRows ?? [])
            : fallbackTargetLengths
        let resolvedSourceWordCount = sourceWordCount ?? resolvedSourceWordLengths.count
        let resolvedTargetRowCount = targetRowCount ?? resolvedTargetRows.count

        let boardShape = LevelBoardShape(
            sourceWordCount: resolvedSourceWordCount,
            sourceWordLengths: resolvedSourceWordLengths,
            targetRowCount: resolvedTargetRowCount,
            targetRowLengths: resolvedTargetRows
        )

        let goldTileExpectations = resolvedAnswers.enumerated().flatMap { rowIndex, answer in
            goldTilesInOrder(from: answer).map { tile in
                GoldTileExpectation(
                    rowIndex: rowIndex,
                    columnIndex: tile.columnIndex,
                    letter: Character(String(tile.letter).uppercased())
                )
            }
        }

        let computedGoldWord = String(goldTileExpectations.map(\.letter))
        let resolvedGoldWord = normalizedGoldWord(goldWord) ?? computedGoldWord
        let resolvedNote = normalizedNote(note)

        return LevelDefinition(
            id: id,
            isActive: active ?? true,
            startingWords: resolvedStartingWords,
            targetRows: resolvedTargetRows,
            answerRows: resolvedAnswerRows,
            boardShape: boardShape,
            criteria: [
                "[ROWS COMPLETED]/[TOTAL ROWS] WORDS",
                normalizedCriterion(criteria2),
                "GOLD TILES SPELL \(resolvedGoldWord) IN ORDER"
            ],
            goldTileExpectations: goldTileExpectations,
            goldWord: resolvedGoldWord,
            note: resolvedNote
        )
    }

    private func normalizedCriterion(_ criterion: String?) -> String? {
        guard let criterion, !criterion.isEmpty else { return nil }
        return criterion
    }

    private func normalizedGoldWord(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedNote(_ value: String?) -> String {
        guard let value else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func goldTilesInOrder(from answer: String) -> [(columnIndex: Int, letter: Character)] {
        var tiles: [(columnIndex: Int, letter: Character)] = []
        var visibleCharacterIndex = 0
        var previousVisibleCharacterIndex: Int?
        var previousCharacter: Character?

        for character in answer {
            if character == "*" {
                if let previousVisibleCharacterIndex, let previousCharacter {
                    tiles.append((columnIndex: previousVisibleCharacterIndex, letter: previousCharacter))
                }
                continue
            }

            previousVisibleCharacterIndex = visibleCharacterIndex
            previousCharacter = character
            visibleCharacterIndex += 1
        }

        return tiles
    }
}

private struct DailyScheduleFileDefinition: Decodable {
    let date: String
    let id: String

    private enum CodingKeys: String, CodingKey {
        case date
        case id = "ID"
    }
}
