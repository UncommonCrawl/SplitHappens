//
//  ContentView.swift
//  SplitHappens
//
//  Created by Keith Herrmann on 4/4/26.
//

import Foundation
import AVFoundation
import AudioToolbox
import SwiftUI
import Charts
import UIKit

struct LetterTile: Identifiable, Equatable {
    let id = UUID()
    let character: String
    let sourceWordIndex: Int
    let positionInWord: Int
}

struct LevelBoardShape: Hashable {
    let sourceWordCount: Int
    let sourceWordLengths: [Int]
    let targetRowCount: Int
    let targetRowLengths: [Int]

    var sourceColumnCount: Int {
        sourceWordLengths.max() ?? 0
    }

    var targetColumnCount: Int {
        targetRowLengths.max() ?? 0
    }
}

struct LevelDefinition {
    let id: String
    let isActive: Bool
    let startingWords: [String]
    let targetRows: [Int]
    let answerRows: [String]
    let boardShape: LevelBoardShape
    let criteriaRegular: String
    let criteriaPerfect: String
    let goldTileExpectations: [GoldTileExpectation]
    let goldWord: String
    let note: String
}

struct GoldTileExpectation {
    let rowIndex: Int
    let columnIndex: Int
    let letter: Character
}

private struct PersistedTilePlacement: Codable, Equatable {
    let sourceWordIndex: Int
    let positionInWord: Int
    let rowIndex: Int
    let columnIndex: Int
}

private enum LevelAchievementBadge: String, CaseIterable {
    case holySplit
    case licketySplit

    var title: String {
        switch self {
        case .holySplit:
            return "Holy Split"
        case .licketySplit:
            return "Lickety Split"
        }
    }

    var systemImage: String {
        switch self {
        case .holySplit:
            return "trophy.circle.fill"
        case .licketySplit:
            return "timer.circle.fill"
        }
    }
}

private struct PersistedLevelProgress: Codable {
    var tilePlacements: [PersistedTilePlacement]
    var hasAchievedSplit: Bool
    var hasAchievedPerfectSplit: Bool
    var moveHistory: [[PersistedTilePlacement]]?
    var hintedRowIndices: [Int]
    var earnedGoldBadges: [String]

    init(
        tilePlacements: [PersistedTilePlacement],
        hasAchievedSplit: Bool,
        hasAchievedPerfectSplit: Bool,
        moveHistory: [[PersistedTilePlacement]]?,
        hintedRowIndices: [Int],
        earnedGoldBadges: [String]
    ) {
        self.tilePlacements = tilePlacements
        self.hasAchievedSplit = hasAchievedSplit
        self.hasAchievedPerfectSplit = hasAchievedPerfectSplit
        self.moveHistory = moveHistory
        self.hintedRowIndices = hintedRowIndices
        self.earnedGoldBadges = earnedGoldBadges
    }

    private enum CodingKeys: String, CodingKey {
        case tilePlacements
        case hasAchievedSplit
        case hasAchievedPerfectSplit
        case achievedCriteria
        case moveHistory
        case hintedRowIndices
        case earnedGoldBadges
        case usedHintBeforeGold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tilePlacements = try container.decode([PersistedTilePlacement].self, forKey: .tilePlacements)
        let legacyCriteria = try container.decodeIfPresent([Bool].self, forKey: .achievedCriteria) ?? []
        hasAchievedSplit = try container.decodeIfPresent(Bool.self, forKey: .hasAchievedSplit)
            ?? (legacyCriteria.indices.contains(0) && legacyCriteria[0])
        hasAchievedPerfectSplit = try container.decodeIfPresent(Bool.self, forKey: .hasAchievedPerfectSplit)
            ?? (legacyCriteria.indices.contains(2) && legacyCriteria[2])
        moveHistory = try container.decodeIfPresent([[PersistedTilePlacement]].self, forKey: .moveHistory)
        hintedRowIndices = try container.decodeIfPresent([Int].self, forKey: .hintedRowIndices) ?? []
        earnedGoldBadges = try container.decodeIfPresent([String].self, forKey: .earnedGoldBadges) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tilePlacements, forKey: .tilePlacements)
        try container.encode(hasAchievedSplit, forKey: .hasAchievedSplit)
        try container.encode(hasAchievedPerfectSplit, forKey: .hasAchievedPerfectSplit)
        try container.encodeIfPresent(moveHistory, forKey: .moveHistory)
        try container.encode(hintedRowIndices, forKey: .hintedRowIndices)
        try container.encode(earnedGoldBadges, forKey: .earnedGoldBadges)
    }
}

private struct PersistedGameProgress: Codable {
    enum PersistedScreen: String, Codable {
        case levels
        case game
    }

    var lastScreen: PersistedScreen?
    var lastPlayedLevelID: String?
    var levelsByID: [String: PersistedLevelProgress]
}

private enum LocalProgressStorage {
    private static let storageKey = "split-happens.progress.v1"

    static func load() -> PersistedGameProgress {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(PersistedGameProgress.self, from: data) else {
            return PersistedGameProgress(lastScreen: nil, lastPlayedLevelID: nil, levelsByID: [:])
        }

        return decoded
    }

    static func update(_ mutation: (inout PersistedGameProgress) -> Void) {
        var snapshot = load()
        mutation(&snapshot)
        save(snapshot)
    }

    static func save(_ snapshot: PersistedGameProgress) {
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }
}

private struct RowLetterQualifier {
    let rowNumber: Int?
    let letter: Character?
    let requiredRowMatchCount: Int
    let isNegated: Bool

    init?(suffix: Substring) {
        var components = suffix
            .split(separator: "_", omittingEmptySubsequences: false)
            .map(String.init)

        guard !components.isEmpty else { return nil }

        var parsedIsNegated = false

        while let lastComponent = components.last {
            if lastComponent == "NONE" {
                parsedIsNegated = true
                components.removeLast()
                continue
            }

            break
        }

        isNegated = parsedIsNegated

        guard !components.isEmpty else { return nil }

        let rowComponent = components[0]
        if rowComponent == "ANY" || rowComponent == CriteriaRuleSet.current.anyRowTokenPlaceholder {
            rowNumber = nil
            requiredRowMatchCount = 1
        } else if rowComponent.hasSuffix("X"),
                  let parsedCount = Int(rowComponent.dropLast()),
                  parsedCount > 0 {
            rowNumber = nil
            requiredRowMatchCount = parsedCount
        } else {
            guard let parsedRow = Int(components[0]), parsedRow > 0 else { return nil }
            rowNumber = parsedRow
            requiredRowMatchCount = 1
        }

        if components.count >= 2 {
            switch components[1] {
            case "ANY", CriteriaRuleSet.current.anyLetterTokenPlaceholder:
                letter = nil
            default:
                guard components[1].count == 1, let parsedLetter = components[1].first else { return nil }
                letter = parsedLetter
            }
        } else {
            letter = nil
        }

        guard components.count <= 2 else { return nil }
    }

    func rowLabel(using rules: CriteriaRuleSet) -> String {
        rules.rowText(rowNumber, matchCount: requiredRowMatchCount)
    }

    func letterLabel(using rules: CriteriaRuleSet) -> String {
        letter.map(String.init) ?? rules.anyLetterLabel
    }

    func matchingWords(in rowWords: [String?]) -> [String] {
        if let rowNumber {
            guard rowWords.indices.contains(rowNumber - 1),
                  let word = rowWords[rowNumber - 1] else {
                return []
            }
            return [word]
        }

        return rowWords.compactMap { $0 }
    }

    func hasRequiredMatches(in rowWords: [String?], where predicate: (String) -> Bool) -> Bool {
        let matchingCount = matchingWords(in: rowWords)
            .filter(predicate)
            .count

        if isNegated {
            return matchingCount == 0
        }

        return matchingCount >= requiredRowMatchCount
    }
}

private struct RowTextQualifier {
    let rowNumber: Int?
    let text: String?
    let requiredRowMatchCount: Int
    let requiredTextInstanceCount: Int
    let isNegated: Bool

    init?(suffix: Substring) {
        var components = suffix
            .split(separator: "_", omittingEmptySubsequences: false)
            .map(String.init)

        guard components.count >= 2 else { return nil }

        var parsedIsNegated = false

        while let lastComponent = components.last {
            if lastComponent == "NONE" {
                parsedIsNegated = true
                components.removeLast()
                continue
            }

            break
        }

        isNegated = parsedIsNegated

        guard components.count >= 2 else { return nil }

        let rowComponent = components[0]
        if rowComponent == "ANY" || rowComponent == CriteriaRuleSet.current.anyRowTokenPlaceholder {
            rowNumber = nil
            requiredRowMatchCount = 1
        } else if rowComponent.hasSuffix("X"),
                  let parsedCount = Int(rowComponent.dropLast()),
                  parsedCount > 0 {
            rowNumber = nil
            requiredRowMatchCount = parsedCount
        } else {
            guard let parsedRow = Int(components[0]), parsedRow > 0 else { return nil }
            rowNumber = parsedRow
            requiredRowMatchCount = 1
        }

        let parsedText = components.dropFirst().joined(separator: "_")
        if parsedText == "ANY" || parsedText == CriteriaRuleSet.current.anyLetterTokenPlaceholder {
            text = nil
            requiredTextInstanceCount = 1
        } else {
            guard !parsedText.isEmpty else { return nil }
            let prefixDigits = parsedText.prefix { $0.isNumber }
            if let parsedCount = Int(prefixDigits), parsedCount > 0 {
                let remainingText = String(parsedText.dropFirst(prefixDigits.count))
                guard !remainingText.isEmpty else { return nil }
                text = remainingText
                requiredTextInstanceCount = parsedCount
            } else {
                text = parsedText
                requiredTextInstanceCount = 1
            }
        }
    }

    func rowLabel(using rules: CriteriaRuleSet) -> String {
        rules.rowText(rowNumber, matchCount: requiredRowMatchCount)
    }

    func textLabel(using rules: CriteriaRuleSet) -> String {
        let baseText = text ?? rules.anyLetterLabel
        guard requiredTextInstanceCount > 1 else { return baseText }
        return "\(requiredTextInstanceCount)\(baseText)"
    }

    func matchingWords(in rowWords: [String?]) -> [String] {
        if let rowNumber {
            guard rowWords.indices.contains(rowNumber - 1),
                  let word = rowWords[rowNumber - 1] else {
                return []
            }
            return [word]
        }

        return rowWords.compactMap { $0 }
    }

    func hasRequiredMatches(in rowWords: [String?], where predicate: (String) -> Bool) -> Bool {
        let matchingCount = matchingWords(in: rowWords)
            .filter(predicate)
            .count

        if isNegated {
            return matchingCount == 0
        }

        return matchingCount >= requiredRowMatchCount
    }
}

private enum LevelCriterion {
    case progress
    case includeWord(String)
    case doubleLetter(RowLetterQualifier)
    case startText(RowTextQualifier)
    case endText(RowTextQualifier)
    case containsText(RowTextQualifier)
    case custom(String)

    init?(rawValue: String?) {
        guard let rawValue = rawValue?
            .removingInvisibleFormattingCharacters()
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty else {
            return nil
        }

        if rawValue == "[ROWS COMPLETED]/[TOTAL ROWS] WORDS" {
            self = .progress
            return
        }

        if rawValue.hasPrefix("INCLUDES_") || rawValue.hasPrefix("INCLUDE_") {
            let prefix = rawValue.hasPrefix("INCLUDES_") ? "INCLUDES_" : "INCLUDE_"
            let word = String(rawValue.dropFirst(prefix.count))
            guard !word.isEmpty else { return nil }
            self = .includeWord(word)
            return
        }

        if let criterion = Self.rowFirstCriterion(from: rawValue) {
            self = criterion
            return
        }

        if rawValue.hasPrefix("DOUBLE_") {
            guard let qualifier = RowLetterQualifier(suffix: rawValue.dropFirst("DOUBLE_".count)) else {
                return nil
            }
            self = .doubleLetter(qualifier)
            return
        }

        if rawValue.hasPrefix("ENDS_") || rawValue.hasPrefix("END_") {
            let prefix = rawValue.hasPrefix("ENDS_") ? "ENDS_" : "END_"
            guard let qualifier = RowTextQualifier(suffix: rawValue.dropFirst(prefix.count)) else {
                return nil
            }
            self = .endText(qualifier)
            return
        }

        if rawValue.hasPrefix("STARTS_") || rawValue.hasPrefix("START_") {
            let prefix = rawValue.hasPrefix("STARTS_") ? "STARTS_" : "START_"
            guard let qualifier = RowTextQualifier(suffix: rawValue.dropFirst(prefix.count)) else {
                return nil
            }
            self = .startText(qualifier)
            return
        }

        if rawValue.hasPrefix("CONTAINS_") {
            guard let qualifier = RowTextQualifier(suffix: rawValue.dropFirst("CONTAINS_".count)) else {
                return nil
            }
            self = .containsText(qualifier)
            return
        }

        self = .custom(rawValue)
    }

    private static func rowFirstCriterion(from rawValue: String) -> LevelCriterion? {
        let components = rawValue.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2 else { return nil }

        let rowToken = components[0]
        let isWildcardRow = rowToken == "ANY" || rowToken == CriteriaRuleSet.current.anyRowTokenPlaceholder
        let isNumberedRow = Int(rowToken).map { $0 > 0 } ?? false
        let isRowCount = Int(rowToken.dropLast()).map { rowToken.hasSuffix("X") && $0 > 0 } ?? false
        guard isWildcardRow || isNumberedRow || isRowCount else { return nil }

        let suffix = ([rowToken] + components.dropFirst(2)).joined(separator: "_")

        switch components[1] {
        case "DOUBLE":
            guard let qualifier = RowLetterQualifier(suffix: Substring(suffix)) else { return nil }
            return .doubleLetter(qualifier)
        case "STARTS", "START":
            guard let qualifier = RowTextQualifier(suffix: Substring(suffix)) else { return nil }
            return .startText(qualifier)
        case "ENDS", "END":
            guard let qualifier = RowTextQualifier(suffix: Substring(suffix)) else { return nil }
            return .endText(qualifier)
        case "CONTAINS":
            guard let qualifier = RowTextQualifier(suffix: Substring(suffix)) else { return nil }
            return .containsText(qualifier)
        default:
            return nil
        }
    }

    func label(completedWords: Int, totalWords: Int, rules: CriteriaRuleSet) -> String {
        switch self {
        case .progress:
            return "\(completedWords)/\(totalWords) VALID WORDS"
        case .includeWord(let word):
            return rules.includeLabel(word: word)
        case .doubleLetter(let qualifier):
            let label = rules.doubleLabel(
                row: qualifier.rowLabel(using: rules),
                letter: qualifier.letterLabel(using: rules)
            )
            return qualifier.isNegated ? rules.negatedLabel(label) : label
        case .startText(let qualifier):
            let label = rules.startLabel(
                row: qualifier.rowLabel(using: rules),
                text: qualifier.textLabel(using: rules)
            )
            return qualifier.isNegated ? rules.negatedLabel(label) : label
        case .endText(let qualifier):
            let label = rules.endLabel(
                row: qualifier.rowLabel(using: rules),
                text: qualifier.textLabel(using: rules)
            )
            return qualifier.isNegated ? rules.negatedLabel(label) : label
        case .containsText(let qualifier):
            let label = rules.containsLabel(
                row: qualifier.rowLabel(using: rules),
                text: qualifier.textLabel(using: rules)
            )
            return qualifier.isNegated ? rules.negatedLabel(label) : label
        case .custom(let label):
            return label
        }
    }

    func isSatisfied(completedWords: Int, totalWords: Int, rowWords: [String?]) -> Bool {
        switch self {
        case .progress:
            return completedWords == totalWords
        case .includeWord(let word):
            let targetWord = word.uppercased()
            return rowWords.contains { candidate in
                guard let candidate else { return false }
                return candidate.uppercased() == targetWord
            }
        case .doubleLetter(let qualifier):
            return qualifier.hasRequiredMatches(in: rowWords) { word in
                let normalizedWord = word.uppercased()
                let normalizedLetter = qualifier.letter.map { Character(String($0).uppercased()) }
                return normalizedWord.containsDoubleLetter(of: normalizedLetter)
            }
        case .startText(let qualifier):
            return qualifier.hasRequiredMatches(in: rowWords) { word in
                guard let text = qualifier.text else { return !word.isEmpty }
                let normalizedWord = word.uppercased()
                let normalizedText = text.uppercased()
                return normalizedWord.hasPrefix(String(repeating: normalizedText, count: qualifier.requiredTextInstanceCount))
            }
        case .endText(let qualifier):
            return qualifier.hasRequiredMatches(in: rowWords) { word in
                guard let text = qualifier.text else { return !word.isEmpty }
                let normalizedWord = word.uppercased()
                let normalizedText = text.uppercased()
                return normalizedWord.hasSuffix(String(repeating: normalizedText, count: qualifier.requiredTextInstanceCount))
            }
        case .containsText(let qualifier):
            return qualifier.hasRequiredMatches(in: rowWords) { word in
                guard let text = qualifier.text else { return !word.isEmpty }
                return word.uppercased().nonOverlappingOccurrenceCount(of: text.uppercased()) >= qualifier.requiredTextInstanceCount
            }
        case .custom:
            return false
        }
    }
}

private extension String {
    func removingInvisibleFormattingCharacters() -> String {
        unicodeScalars
            .filter { scalar in
                !["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}"].contains(String(scalar))
            }
            .map(String.init)
            .joined()
    }

    func containsDoubleLetter(of letter: Character?) -> Bool {
        zip(self, self.dropFirst()).contains { lhs, rhs in
            guard lhs == rhs else { return false }
            guard lhs.isLetter else { return false }
            guard let letter else { return true }
            return lhs == letter
        }
    }

    func nonOverlappingOccurrenceCount(of searchText: String) -> Int {
        guard !searchText.isEmpty else { return 0 }

        var count = 0
        var searchStartIndex = startIndex

        while searchStartIndex < endIndex,
              let range = range(of: searchText, range: searchStartIndex..<endIndex) {
            count += 1
            searchStartIndex = range.upperBound
        }

        return count
    }

    var answerWord: String {
        filter { $0 != "*" }
    }

    var goldTilesInOrder: [(columnIndex: Int, letter: Character)] {
        var tiles: [(columnIndex: Int, letter: Character)] = []
        var visibleCharacterIndex = 0
        var previousVisibleCharacterIndex: Int?
        var previousCharacter: Character?

        for character in self {
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

    var goldLetters: [Character] {
        goldTilesInOrder.map(\.letter)
    }
}

private enum CriteriaRuleLoader {
    static func loadRuleSet() -> CriteriaRuleSet {
        CriteriaRuleSet.current
    }
}

struct WordList {
    private let words: Set<String>

    init() {
        guard let url = ResourceBundle.url(forResource: "words", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            words = []
            return
        }

        words = Set(decoded)
    }

    func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }
}

private enum ResourceBundle {
    static func url(forResource name: String, withExtension ext: String, subdirectory: String? = nil) -> URL? {
        if let subdirectory,
           let subdirURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return subdirURL
        }

        if let directURL = Bundle.main.url(forResource: name, withExtension: ext) {
            return directURL
        }

        guard let bundle = CFBundleGetMainBundle(),
              let resourceURL = CFBundleCopyResourceURL(
                bundle,
                name as CFString,
                ext as CFString,
                subdirectory as CFString?
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
}

@Observable
final class GameState {
    static let sharedWordList = WordList()

    let sourceWords: [String]
    let targetRowSizes: [Int]
    private(set) var letters: [LetterTile] = []
    private let lettersBySourceWord: [[LetterTile]]
    private let lettersByID: [UUID: LetterTile]
    private(set) var slotIDs: [[UUID]] = []
    private(set) var goldSlotIDs: Set<UUID> = []
    private(set) var goldSlotExpectations: [(slotID: UUID, letter: Character)] = []
    private(set) var placements: [UUID: UUID] = [:]
    private var slotOccupants: [UUID: UUID] = [:]
    private var sourceSlotOccupants: [UUID: UUID] = [:]
    private var sourceSlotByLetterID: [UUID: UUID] = [:]
    private let letterIDBySourcePosition: [String: UUID]
    private let slotIDByTargetPosition: [String: UUID]
    private let slotPositionByID: [UUID: (rowIndex: Int, columnIndex: Int)]
    let wordList: WordList

    init(
        sourceWords: [String],
        targetRowSizes: [Int],
        goldTileExpectations: [GoldTileExpectation] = [],
        wordList: WordList = GameState.sharedWordList
    ) {
        self.sourceWords = sourceWords
        self.targetRowSizes = targetRowSizes
        self.wordList = wordList

        var builtLetters: [LetterTile] = []
        var builtLettersBySourceWord: [[LetterTile]] = []

        for (wordIndex, word) in sourceWords.enumerated() {
            var rowLetters: [LetterTile] = []

            for (characterIndex, character) in word.enumerated() {
                let letter = LetterTile(
                    character: String(character),
                    sourceWordIndex: wordIndex,
                    positionInWord: characterIndex
                )
                rowLetters.append(letter)
                builtLetters.append(letter)
            }

            builtLettersBySourceWord.append(rowLetters)
        }

        letters = builtLetters
        lettersBySourceWord = builtLettersBySourceWord
        lettersByID = Dictionary(uniqueKeysWithValues: builtLetters.map { ($0.id, $0) })
        sourceSlotOccupants = Dictionary(uniqueKeysWithValues: builtLetters.map { ($0.id, $0.id) })
        sourceSlotByLetterID = Dictionary(uniqueKeysWithValues: builtLetters.map { ($0.id, $0.id) })

        let builtSlotIDs = targetRowSizes.map { size in
            (0..<size).map { _ in UUID() }
        }
        slotIDs = builtSlotIDs

        var builtLetterIDBySourcePosition: [String: UUID] = [:]
        for letter in builtLetters {
            let key = Self.sourcePositionKey(
                sourceWordIndex: letter.sourceWordIndex,
                positionInWord: letter.positionInWord
            )
            builtLetterIDBySourcePosition[key] = letter.id
        }
        letterIDBySourcePosition = builtLetterIDBySourcePosition

        var builtSlotIDByTargetPosition: [String: UUID] = [:]
        var builtSlotPositionByID: [UUID: (rowIndex: Int, columnIndex: Int)] = [:]
        for (rowIndex, rowSlotIDs) in builtSlotIDs.enumerated() {
            for (columnIndex, slotID) in rowSlotIDs.enumerated() {
                let key = Self.targetPositionKey(rowIndex: rowIndex, columnIndex: columnIndex)
                builtSlotIDByTargetPosition[key] = slotID
                builtSlotPositionByID[slotID] = (rowIndex: rowIndex, columnIndex: columnIndex)
            }
        }
        slotIDByTargetPosition = builtSlotIDByTargetPosition
        slotPositionByID = builtSlotPositionByID

        for expectation in goldTileExpectations {
            guard slotIDs.indices.contains(expectation.rowIndex),
                  slotIDs[expectation.rowIndex].indices.contains(expectation.columnIndex) else {
                continue
            }

            let slotID = slotIDs[expectation.rowIndex][expectation.columnIndex]
            goldSlotIDs.insert(slotID)
            goldSlotExpectations.append((slotID: slotID, letter: expectation.letter))
        }
    }

    func lettersForWord(_ wordIndex: Int) -> [LetterTile] {
        guard lettersBySourceWord.indices.contains(wordIndex) else { return [] }
        return lettersBySourceWord[wordIndex]
    }

    func sourceSlotID(wordIndex: Int, columnIndex: Int) -> UUID? {
        guard lettersBySourceWord.indices.contains(wordIndex),
              lettersBySourceWord[wordIndex].indices.contains(columnIndex) else {
            return nil
        }

        return lettersBySourceWord[wordIndex][columnIndex].id
    }

    func wordForRow(_ rowIndex: Int) -> String? {
        let row = slotIDs[rowIndex]
        var result = ""

        for slotID in row {
            guard let letter = letterInSlot(slotID) else { return nil }
            result += letter.character
        }

        return result
    }

    func criteriaWordForRow(_ rowIndex: Int) -> String? {
        let row = slotIDs[rowIndex]
        var result = ""
        var hasPlacedLetter = false

        for slotID in row {
            if let letter = letterInSlot(slotID) {
                result += letter.character
                hasPlacedLetter = true
            } else {
                result += "_"
            }
        }

        return hasPlacedLetter ? result : nil
    }

    func isRowValid(_ rowIndex: Int) -> Bool {
        guard let word = wordForRow(rowIndex) else { return false }
        return wordList.contains(word)
    }

    func isPlaced(_ letter: LetterTile) -> Bool {
        placements[letter.id] != nil
    }

    func letterInSlot(_ slotID: UUID) -> LetterTile? {
        guard let letterID = slotOccupants[slotID] else { return nil }
        return lettersByID[letterID]
    }

    func letter(byID id: UUID) -> LetterTile? {
        lettersByID[id]
    }

    func letterInSourceSlot(_ sourceSlotID: UUID) -> LetterTile? {
        guard let letterID = sourceSlotOccupants[sourceSlotID] else { return nil }
        return lettersByID[letterID]
    }

    func letterID(sourceWordIndex: Int, positionInWord: Int) -> UUID? {
        letterIDBySourcePosition[Self.sourcePositionKey(
            sourceWordIndex: sourceWordIndex,
            positionInWord: positionInWord
        )]
    }

    func isGoldSlot(_ slotID: UUID) -> Bool {
        goldSlotIDs.contains(slotID)
    }

    func slotID(rowIndex: Int, columnIndex: Int) -> UUID? {
        slotIDByTargetPosition[Self.targetPositionKey(rowIndex: rowIndex, columnIndex: columnIndex)]
    }

    func slotPosition(for slotID: UUID) -> (rowIndex: Int, columnIndex: Int)? {
        slotPositionByID[slotID]
    }

    func goldLetterMatchesInOrder() -> [Bool] {
        goldSlotExpectations.map { expectation in
            guard let placedCharacter = letterInSlot(expectation.slotID)?.character.first else {
                return false
            }

            return Character(String(placedCharacter).uppercased()) == expectation.letter
        }
    }

    func isCorrectlyPlacedGoldSlot(_ slotID: UUID) -> Bool {
        guard let expectation = goldSlotExpectations.first(where: { $0.slotID == slotID }),
              let placedCharacter = letterInSlot(slotID)?.character.first else {
            return false
        }

        return Character(String(placedCharacter).uppercased()) == expectation.letter
    }

    func place(letterID: UUID, inSlot slotID: UUID) {
        if placements[letterID] == slotID { return }

        let previousSlotID = placements[letterID]
        let previousSourceSlotID = sourceSlotByLetterID.removeValue(forKey: letterID)
        if let previousSourceSlotID {
            sourceSlotOccupants.removeValue(forKey: previousSourceSlotID)
        }
        let displacedLetterID = slotOccupants[slotID]

        if let previousSlotID, previousSlotID != slotID {
            slotOccupants.removeValue(forKey: previousSlotID)
        }

        if let displacedLetterID, displacedLetterID != letterID, let previousSlotID {
            placements[displacedLetterID] = previousSlotID
            slotOccupants[previousSlotID] = displacedLetterID
        } else if let displacedLetterID {
            placements.removeValue(forKey: displacedLetterID)
            placeInSource(letterID: displacedLetterID, preferredSlotID: previousSourceSlotID)
        }

        placements[letterID] = slotID
        slotOccupants[slotID] = letterID
    }

    func returnToSource(letterID: UUID, preferredSourceSlotID: UUID? = nil) {
        placeInSource(letterID: letterID, preferredSlotID: preferredSourceSlotID)
    }

    func returnToSourceWithoutSwap(letterID: UUID, preferredSourceSlotID: UUID? = nil) {
        placeInSourceWithoutSwap(letterID: letterID, preferredSlotID: preferredSourceSlotID)
    }

    func firstAvailableSourceSlotID() -> UUID? {
        firstEmptySourceSlotID()
    }

    func recallAll() {
        placements.removeAll()
        slotOccupants.removeAll()
        sourceSlotOccupants = Dictionary(uniqueKeysWithValues: letters.map { ($0.id, $0.id) })
        sourceSlotByLetterID = Dictionary(uniqueKeysWithValues: letters.map { ($0.id, $0.id) })
    }

    private func placeInSource(letterID: UUID, preferredSlotID: UUID?) {
        if let previousTargetSlotID = placements.removeValue(forKey: letterID) {
            slotOccupants.removeValue(forKey: previousTargetSlotID)
        }

        let previousSourceSlotID = sourceSlotByLetterID.removeValue(forKey: letterID)
        if let previousSourceSlotID {
            sourceSlotOccupants.removeValue(forKey: previousSourceSlotID)
        }

        let destinationSlotID = resolvedSourceDestination(preferredSlotID: preferredSlotID, letterID: letterID)
        guard let destinationSlotID else { return }

        if let displacedLetterID = sourceSlotOccupants[destinationSlotID],
           displacedLetterID != letterID {
            sourceSlotByLetterID.removeValue(forKey: displacedLetterID)
            if let swapSlotID = previousSourceSlotID,
               swapSlotID != destinationSlotID,
               sourceSlotOccupants[swapSlotID] == nil {
                sourceSlotOccupants[swapSlotID] = displacedLetterID
                sourceSlotByLetterID[displacedLetterID] = swapSlotID
            } else if let fallbackSlotID = firstEmptySourceSlotID(excluding: destinationSlotID) {
                sourceSlotOccupants[fallbackSlotID] = displacedLetterID
                sourceSlotByLetterID[displacedLetterID] = fallbackSlotID
            }
        }

        sourceSlotOccupants[destinationSlotID] = letterID
        sourceSlotByLetterID[letterID] = destinationSlotID
    }

    private func placeInSourceWithoutSwap(letterID: UUID, preferredSlotID: UUID?) {
        if let previousTargetSlotID = placements.removeValue(forKey: letterID) {
            slotOccupants.removeValue(forKey: previousTargetSlotID)
        }

        let previousSourceSlotID = sourceSlotByLetterID.removeValue(forKey: letterID)
        if let previousSourceSlotID {
            sourceSlotOccupants.removeValue(forKey: previousSourceSlotID)
        }

        let destinationSlotID = resolvedSourceDestinationWithoutSwap(preferredSlotID: preferredSlotID, letterID: letterID)
        guard let destinationSlotID else { return }

        sourceSlotOccupants[destinationSlotID] = letterID
        sourceSlotByLetterID[letterID] = destinationSlotID
    }

    private func resolvedSourceDestination(preferredSlotID: UUID?, letterID: UUID) -> UUID? {
        if let preferredSlotID, lettersByID[preferredSlotID] != nil {
            return preferredSlotID
        }

        if let emptySlotID = firstEmptySourceSlotID() {
            return emptySlotID
        }

        return lettersByID[letterID] != nil ? letterID : nil
    }

    private func resolvedSourceDestinationWithoutSwap(preferredSlotID: UUID?, letterID: UUID) -> UUID? {
        if let preferredSlotID, lettersByID[preferredSlotID] != nil {
            if sourceSlotOccupants[preferredSlotID] == nil {
                return preferredSlotID
            }

            if let nextEmptySlotID = nextEmptySourceSlotID(after: preferredSlotID) {
                return nextEmptySlotID
            }
        }

        if let emptySlotID = firstEmptySourceSlotID() {
            return emptySlotID
        }

        return lettersByID[letterID] != nil ? letterID : nil
    }

    private func firstEmptySourceSlotID(excluding excludedSlotID: UUID? = nil) -> UUID? {
        for row in lettersBySourceWord {
            for sourceSlot in row {
                let sourceSlotID = sourceSlot.id
                if sourceSlotID == excludedSlotID { continue }
                if sourceSlotOccupants[sourceSlotID] == nil {
                    return sourceSlotID
                }
            }
        }

        return nil
    }

    private func nextEmptySourceSlotID(after sourceSlotID: UUID) -> UUID? {
        let orderedSourceSlotIDs = lettersBySourceWord.flatMap { row in row.map(\.id) }
        guard let startIndex = orderedSourceSlotIDs.firstIndex(of: sourceSlotID) else {
            return nil
        }

        for offset in 1..<orderedSourceSlotIDs.count {
            let candidateIndex = (startIndex + offset) % orderedSourceSlotIDs.count
            let candidateSlotID = orderedSourceSlotIDs[candidateIndex]
            if sourceSlotOccupants[candidateSlotID] == nil {
                return candidateSlotID
            }
        }

        return nil
    }

    private static func sourcePositionKey(sourceWordIndex: Int, positionInWord: Int) -> String {
        "\(sourceWordIndex):\(positionInWord)"
    }

    private static func targetPositionKey(rowIndex: Int, columnIndex: Int) -> String {
        "\(rowIndex):\(columnIndex)"
    }
}

struct SourceGridFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull {
            value = next
        }
    }
}

struct TargetGridFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull {
            value = next
        }
    }
}

private enum BoardUI {
    static let horizontalPadding: CGFloat = 24
    static let titleBarSidePadding: CGFloat = 20
    static let topPadding: CGFloat = 0
    static let bottomPadding: CGFloat = 0
    static let compactMaxContentWidth: CGFloat = 460
    static let expandedMaxContentWidth: CGFloat = 620
    static let expandedLayoutMinWidth: CGFloat = 700

    static let sectionSpacing: CGFloat = 0
    static let boardSpacing: CGFloat = 0
    static let sourceTileSpacing: CGFloat = 5
    static var sourceTileRowSpacing: CGFloat { sourceTileSpacing * 2 }
    static let targetTileHorizontalSpacing: CGFloat = 4
    static let targetTileVerticalSpacing: CGFloat = 12
    static let criteriaSpacing: CGFloat = 12
    static let criteriaCount = 2
    static let criteriaHorizontalInset: CGFloat = 0
    static let criteriaGateSize: CGFloat = 18
    static var criteriaTabSpacing: CGFloat = 0
    static let titleBarHeight: CGFloat = 44
    static let gameHeaderBottomMargin: CGFloat = 30

    static let sourceSectionWeight: CGFloat = 0.24
    static let targetSectionWeight: CGFloat = 0.48
    static let criteriaSectionWeight: CGFloat = 0.28
    static let minimumSourceSectionHeight: CGFloat = 96
    static let minimumTargetSectionHeight: CGFloat = 220
    static let minimumCriteriaSectionHeight: CGFloat = 140

    static let titleFontSize: CGFloat = 28
    static let recallFontSize: CGFloat = 17
    static let titleBarNavIconSize: CGFloat = 34
    static let bottomActionBarIconSize: CGFloat = 42
    static var hintIconSize: CGFloat { bottomActionBarIconSize * 1.2 }
    static let navButtonWidth: CGFloat = 44

    static let sourceTileBaseSize: CGFloat = 38
    static let targetTileBaseSize: CGFloat = 52
    static let sourceTileExpandedBaseSize: CGFloat = 56
    static let targetTileExpandedBaseSize: CGFloat = 78
    static let minimumSourceTileSize: CGFloat = 24
    static let minimumTargetTileSize: CGFloat = 32

    static let sourceTileCornerRatio: CGFloat = 0.1
    static let targetTileCornerRatio: CGFloat = 0.1

    static var targetDividerVerticalPadding: CGFloat {
        max((targetTileVerticalSpacing - 1) / 2, 0)
    }

    static var targetRowSeparatorHeight: CGFloat {
        1 + (targetDividerVerticalPadding * 2)
    }
}

private struct BoardGridMetrics: Hashable {
    let sourceRows: Int
    let sourceColumns: Int
    let targetRows: Int
    let targetColumns: Int

    init(levels: [LevelDefinition]) {
        sourceRows = max(1, levels.map(\.boardShape.sourceWordCount).max() ?? 1)
        sourceColumns = max(1, levels.map(\.boardShape.sourceColumnCount).max() ?? 1)
        targetRows = max(1, levels.map(\.boardShape.targetRowCount).max() ?? 1)
        targetColumns = max(1, levels.map(\.boardShape.targetColumnCount).max() ?? 1)
    }

    init(level: LevelDefinition) {
        sourceRows = max(1, level.boardShape.sourceWordCount)
        sourceColumns = max(1, level.boardShape.sourceColumnCount)
        targetRows = max(1, level.boardShape.targetRowCount)
        targetColumns = max(1, level.boardShape.targetColumnCount)
    }
}

private enum AppColor {
    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red / 255
            self.green = green / 255
            self.blue = blue / 255
        }

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }

        func tinted(with tint: RGB, amount: Double) -> RGB {
            let baseAmount = 1 - amount
            return RGB(
                rawRed: red * baseAmount + tint.red * amount,
                rawGreen: green * baseAmount + tint.green * amount,
                rawBlue: blue * baseAmount + tint.blue * amount
            )
        }

        private init(rawRed: Double, rawGreen: Double, rawBlue: Double) {
            red = rawRed
            green = rawGreen
            blue = rawBlue
        }
    }

    private enum Swatch {
        static let board = RGB(255, 255, 255)
        static let standardTile = RGB(248, 238, 210)
        static let placeholderTile = RGB(222, 222, 222)
        static let splitGreen = RGB(255, 216, 107)
        static let perfectGridGold = RGB(255, 216, 107)
        static let achievementGold = RGB(255, 216, 107)
        static let goldAccent = RGB(247, 185, 0)
        static let letterGreen = RGB(73, 159, 45)
        static let controlGray = RGB(96, 96, 96)
        static let shadowBrown = RGB(68, 51, 30)
        static let solvedTileGreen = RGB(222, 241, 211)
    }

    private static let levelTileSealTintAmount = 0.6

    // Surfaces
    static let boardBackground = Swatch.board.color
    static let tileFill = Swatch.standardTile.color
    static let tilePlaceholder = Swatch.placeholderTile.color

    // Level Grid
    static let splitTileFill = Swatch.splitGreen.color
    static let perfectSplitTileFill = Swatch.perfectGridGold.color
    static let tileSeal = levelTileSeal(over: Swatch.standardTile)
    static let splitTileSeal = levelTileSeal(over: Swatch.splitGreen)
    static let perfectSplitTileSeal = levelTileSeal(over: Swatch.perfectGridGold)
    static let tileGridBadgeAccent = buttonActive

    // Letter Tile States
    static let tileCorrect = Swatch.solvedTileGreen.color
    static let tileIncorrect = Swatch.solvedTileGreen.color
    static let letterCorrect = Swatch.letterGreen.color

    // Achievements
    static let split = Swatch.splitGreen.color
    static let perfectSplit = Swatch.achievementGold.color
    static let criteriaGold = Swatch.achievementGold.color
    static let goldDark = Swatch.goldAccent.color
    static let darkGold = goldDark
    static let noBadge = Swatch.placeholderTile.color

    // Controls And Text
    static let buttonActive = Swatch.controlGray.color
    static let criteriaLabel = Swatch.controlGray.tinted(with: Swatch.placeholderTile, amount: 0.5).color
    static let textDefault = Color.black
    static let selection = Color.black.opacity(0.3)
    static let opaqueText = Color.black.opacity(0.3)

    // Effects
    static let tileInnerShadow = Swatch.shadowBrown.color.opacity(0.1)

    private static func levelTileSeal(over base: RGB) -> Color {
        base.tinted(with: Swatch.board, amount: levelTileSealTintAmount).color
    }
}

private enum PerfLog {
    static func log(_ message: String) {
        let ms = Int((CFAbsoluteTimeGetCurrent() * 1000).rounded())
        print("[Perf][\(ms)] \(message)")
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct PopupSheetScaffold<Actions: View>: View {
    let iconSystemName: String?
    let iconAssetName: String?
    let iconAssetTint: Color?
    let title: String
    let bodyLines: [String]
    let bodyLineFontSize: CGFloat?
    let bodyLineFontWeight: Font.Weight
    let spacingAfterTitle: CGFloat
    let spacingAfterBodyLines: CGFloat
    let secondaryTitle: String?
    let secondaryBodyLines: [String]
    let showsActionArea: Bool
    let pinActionAreaToBottom: Bool
    let actionAreaBottomPadding: CGFloat?
    let onClose: (() -> Void)?
    let actions: Actions

    init(
        iconSystemName: String? = nil,
        iconAssetName: String? = nil,
        iconAssetTint: Color? = nil,
        title: String,
        bodyLines: [String],
        bodyLineFontSize: CGFloat? = nil,
        bodyLineFontWeight: Font.Weight = .regular,
        spacingAfterTitle: CGFloat = 12,
        spacingAfterBodyLines: CGFloat = 12,
        secondaryTitle: String? = nil,
        secondaryBodyLines: [String] = [],
        showsActionArea: Bool = true,
        pinActionAreaToBottom: Bool = false,
        actionAreaBottomPadding: CGFloat? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.iconSystemName = iconSystemName
        self.iconAssetName = iconAssetName
        self.iconAssetTint = iconAssetTint
        self.title = title
        self.bodyLines = bodyLines
        self.bodyLineFontSize = bodyLineFontSize
        self.bodyLineFontWeight = bodyLineFontWeight
        self.spacingAfterTitle = spacingAfterTitle
        self.spacingAfterBodyLines = spacingAfterBodyLines
        self.secondaryTitle = secondaryTitle
        self.secondaryBodyLines = secondaryBodyLines
        self.showsActionArea = showsActionArea
        self.pinActionAreaToBottom = pinActionAreaToBottom
        self.actionAreaBottomPadding = actionAreaBottomPadding
        self.onClose = onClose
        self.actions = actions()
    }

    private func bodyLineText(_ line: String, baseSize: CGFloat) -> Text {
        styledInlineText(
            line,
            highlights: [
                .init(phrase: "valid English word", color: AppColor.textDefault, weight: .semibold),
                .init(phrase: "Split", color: AppColor.split, weight: .semibold),
                .init(phrase: "Perfect Split", color: AppColor.darkGold, weight: .semibold),
                .init(phrase: "Shuffle", color: AppColor.textDefault, weight: .semibold),
                .init(phrase: "Hint", color: AppColor.textDefault, weight: .semibold),
                .init(phrase: "Good luck!", color: AppColor.textDefault, weight: .semibold)
            ],
            baseSize: baseSize
        )
    }

    private struct InlineHighlight {
        let phrase: String
        let color: Color
        let weight: Font.Weight
    }

    private func popupGridTileSize(containerWidth: CGFloat) -> CGFloat {
        let horizontalPadding = BoardUI.horizontalPadding
        let safeWidth = max(containerWidth - (horizontalPadding * 2), 220)
        let stackWidth = min(safeWidth, BoardUI.compactMaxContentWidth)
        let horizontalSafeZone = stackWidth * 0.05
        let tileStackWidth = max(120, stackWidth - (horizontalSafeZone * 2))
        let tileSpacing = max(BoardUI.targetTileHorizontalSpacing * 2, 16)
        return max(56, floor((tileStackWidth - (tileSpacing * 2)) / 3))
    }

    private var popupGridTileSize: CGFloat {
        let containerWidth = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .windowScene?
            .screen
            .bounds
            .width ?? 390
        return popupGridTileSize(containerWidth: containerWidth)
    }

    // Reusable inline text styler: declare token/color/weight pairs per line as needed.
    private func styledInlineText(_ text: String, highlights: [InlineHighlight], baseSize: CGFloat) -> Text {
        var attributed = AttributedString(text)
        attributed.font = .system(size: baseSize, weight: bodyLineFontWeight)
        attributed.foregroundColor = AppColor.textDefault.opacity(0.9)

        for highlight in highlights where !highlight.phrase.isEmpty {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex {
                let searchSlice = attributed[searchStart..<attributed.endIndex]
                guard let range = searchSlice.range(of: highlight.phrase) else {
                    break
                }
                attributed[range].foregroundColor = highlight.color
                attributed[range].font = .system(size: baseSize, weight: highlight.weight)
                searchStart = range.upperBound
            }
        }

        return Text(attributed)
    }

    var body: some View {
        let gridTileSize = popupGridTileSize
        let popupInset = gridTileSize * 0.4
        let titleSize = gridTileSize * 0.4
        let resolvedBodyLineSize = bodyLineFontSize ?? (gridTileSize * 0.2)
        let resolvedActionAreaBottomPadding = actionAreaBottomPadding ?? popupInset

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let iconAssetName {
                    Image(iconAssetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(iconAssetTint ?? AppColor.textDefault)
                        .frame(width: 144, height: 96)
                } else if let iconSystemName {
                    Image(systemName: iconSystemName)
                        .font(.system(size: titleSize, weight: .bold))
                        .foregroundStyle(AppColor.textDefault)
                }

                Text(title)
                    .font(.system(size: titleSize, weight: .heavy))
                    .foregroundStyle(AppColor.textDefault)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, spacingAfterTitle)

                if !bodyLines.isEmpty {
                    VStack(spacing: 20) {
                        ForEach(Array(bodyLines.enumerated()), id: \.offset) { _, line in
                            bodyLineText(line, baseSize: resolvedBodyLineSize)
                                .multilineTextAlignment(.center)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(0)
                        }
                    }
                    .padding(.bottom, spacingAfterBodyLines)
                }

                if secondaryTitle != nil || !secondaryBodyLines.isEmpty {
                    VStack(spacing: 10) {
                        if let secondaryTitle {
                            Text(secondaryTitle)
                                .font(.system(size: 30, weight: .heavy))
                                .foregroundStyle(AppColor.textDefault)
                                .multilineTextAlignment(.center)
                        }

                        ForEach(Array(secondaryBodyLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(AppColor.textDefault.opacity(0.9))
                                .multilineTextAlignment(.center)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(10)
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, popupInset)
            .padding(.top, popupInset)
            .padding(.bottom, showsActionArea ? 0 : popupInset)

            if pinActionAreaToBottom {
                Spacer(minLength: 0)
            }

            if showsActionArea {
                VStack(spacing: 10) {
                    actions
                }
                .padding(.horizontal, popupInset)
                .padding(.top, 10)
                .padding(.bottom, resolvedActionAreaBottomPadding)
                .background(AppColor.boardBackground)
            }

            if !pinActionAreaToBottom {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppColor.boardBackground.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppColor.textDefault)
                        .frame(width: 44, height: 44)
                }
                .contentShape(Rectangle())
                .frame(width: 88, height: 88)
                .buttonStyle(.plain)
                .padding(.top, -12)
                .padding(.trailing, -10)
            }
        }
    }
}

private struct PopupActionButton: View {
    let title: String
    let foregroundColor: Color
    let action: () -> Void
    
    private var usesSecondaryTitleStyle: Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedTitle == "got it"
            || normalizedTitle == "close"
            || normalizedTitle == "how to play"
            || normalizedTitle == "about"
            || normalizedTitle.hasPrefix("sound:")
            || normalizedTitle.hasPrefix("haptics:")
            || normalizedTitle.contains("@")
    }
    
    private var buttonFont: Font {
        if usesSecondaryTitleStyle {
            return .system(size: 30, weight: .heavy)
        }
        return .system(size: 24, weight: .bold)
    }

    init(
        title: String,
        foregroundColor: Color = AppColor.textDefault,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.foregroundColor = foregroundColor
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(buttonFont)
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

private struct PopupSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let candidate = nextValue()
        if candidate > 0 {
            value = candidate
        }
    }
}

private struct IntroPopupView: View {
    let onClose: () -> Void

    var body: some View {
        PopupSheetScaffold(
            title: "How To Play",
            bodyLines: [
                "Rearrange every letter to form a valid English word in each row.",
                "A Split is earned when every row is filled with a valid word.",
                "A Perfect Split is earned when the gold tiles spell the bonus word in order.",
                "Use the Hint button to fill in a word from the official answer key. (Each puzzle may have multiple correct solutions!)",
                "Good luck!"
            ],
            onClose: onClose,
            actions: {
                PopupActionButton(title: "Got It", action: onClose)
            }
        )
    }
}

private struct LevelNotePopupView: View {
    let note: String

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 20)

            Text("Level Info")
                .font(.system(size: 32, weight: .heavy))
                .foregroundStyle(AppColor.textDefault)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)

            Text(note)
                .font(.system(size: 20, weight: .regular))
                .italic()
                .foregroundStyle(AppColor.textDefault.opacity(0.95))
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .background(AppColor.boardBackground.ignoresSafeArea())
    }
}

private struct StatsPopupView: View {
    let played: Int
    let split: Int
    let perfectSplit: Int
    let noBadge: Int
    let onResetProgress: () -> Void
    let onClose: () -> Void
    @State private var showingResetConfirmation = false

    private struct DonutSlice: Identifiable {
        let id: String
        let label: String
        let value: Int
        let color: Color
    }

    private var slices: [DonutSlice] {
        [
            DonutSlice(id: "perfectSplit", label: "Perfect Split", value: perfectSplit, color: AppColor.perfectSplit),
            DonutSlice(id: "split", label: "Split", value: split, color: AppColor.split),
            DonutSlice(id: "none", label: "N/A", value: noBadge, color: AppColor.tileFill)
        ]
    }
    
    private var totalSliceCount: Int {
        max(slices.reduce(0) { $0 + $1.value }, 0)
    }
    
    private func percentageText(for value: Int) -> String {
        guard totalSliceCount > 0 else { return "0%" }
        let percentage = Int((Double(value) / Double(totalSliceCount) * 100).rounded())
        return "\(percentage)%"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Color.clear
                    .frame(height: 20)

                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Levels", slice.value),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.6
                    )
                    .foregroundStyle(slice.color)
                    .cornerRadius(4)
                }
                .frame(height: 170)
                .padding(.horizontal, 24)

                VStack(spacing: 20) {
                    ForEach(slices) { slice in
                        HStack(spacing: 10) {
                            Text(slice.label)
                                .font(.system(size: 30, weight: .heavy))
                                .foregroundStyle(AppColor.textDefault)

                            Spacer()

                            Text("\(slice.value)")
                                .font(.system(size: 30, weight: .heavy))
                                .foregroundStyle(AppColor.textDefault)
                            
                            Text(percentageText(for: slice.value))
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(AppColor.textDefault.opacity(0.75))
                        }
                        .frame(width: 350)
                    }
                }
                .padding(.horizontal, 40)
            }

            Button {
                showingResetConfirmation = true
            } label: {
                Text("Reset Progress")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppColor.textDefault)
            }
            .buttonStyle(.plain)
            .padding(.top, 80)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background(AppColor.boardBackground.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppColor.textDefault)
                    .frame(width: 44, height: 44)
            }
            .contentShape(Rectangle())
            .frame(width: 88, height: 88)
            .buttonStyle(.plain)
            .padding(.top, -12)
            .padding(.trailing, -10)
        }
        .alert("Reset All Progress?", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                onResetProgress()
            }
        } message: {
            Text("This clears all saved level progress and special badges.")
                .multilineTextAlignment(.center)
        }

    }
}

private struct SettingsPopupView: View {
    let isSoundEnabled: Bool
    let isHapticsEnabled: Bool
    let onHowToPlay: () -> Void
    let onViewStats: () -> Void
    let onAbout: () -> Void
    let onFeedbackEmail: () -> Void
    let onToggleSound: () -> Void
    let onToggleHaptics: () -> Void
    let onClose: () -> Void

    var body: some View {
        PopupSheetScaffold(
            title: "Settings",
            bodyLines: [],
            onClose: onClose,
            actions: {
                VStack(spacing: 20) {
                    PopupActionButton(title: "How To Play", action: onHowToPlay)
                    PopupActionButton(title: "About", action: onAbout)
                    PopupActionButton(
                        title: "Sound: \(isSoundEnabled ? "ON" : "OFF")",
                        foregroundColor: isSoundEnabled ? AppColor.textDefault : AppColor.buttonActive,
                        action: onToggleSound
                    )
                    PopupActionButton(
                        title: "Haptics: \(isHapticsEnabled ? "ON" : "OFF")",
                        foregroundColor: isHapticsEnabled ? AppColor.textDefault : AppColor.buttonActive,
                        action: onToggleHaptics
                    )
                    Button(action: onFeedbackEmail) {
                        VStack(spacing: 6) {
                            Image(systemName: "envelope")
                                .font(.system(size: 50, weight: .regular))
                            Text("Got Feedback?")
                                .font(.system(size: 24, weight: .bold))
                        }
                        .foregroundStyle(AppColor.textDefault)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        )
    }
}

private struct BoardLayout {
    private struct CacheKey: Hashable {
        let width: Int
        let height: Int
        let topInset: Int
        let leadingInset: Int
        let bottomInset: Int
        let trailingInset: Int
        let sourceRows: Int
        let sourceColumns: Int
        let targetRows: Int
        let targetColumns: Int

        init(
            availableWidth: CGFloat,
            availableHeight: CGFloat,
            safeAreaInsets: EdgeInsets,
            grid: BoardGridMetrics
        ) {
            func quantize(_ value: CGFloat) -> Int {
                Int((value * 100).rounded())
            }

            width = quantize(availableWidth)
            height = quantize(availableHeight)
            topInset = quantize(safeAreaInsets.top)
            leadingInset = quantize(safeAreaInsets.leading)
            bottomInset = quantize(safeAreaInsets.bottom)
            trailingInset = quantize(safeAreaInsets.trailing)
            sourceRows = grid.sourceRows
            sourceColumns = grid.sourceColumns
            targetRows = grid.targetRows
            targetColumns = grid.targetColumns
        }
    }

    private static var cache: [CacheKey: BoardLayout] = [:]

    let grid: BoardGridMetrics
    let contentWidth: CGFloat
    let sourceSectionHeight: CGFloat
    let targetSectionHeight: CGFloat
    let criteriaSectionHeight: CGFloat
    let minimumSharedWidth: CGFloat
    let sourceTileSize: CGFloat
    let targetTileSize: CGFloat
    let sharedStackWidth: CGFloat
    let sourceBoardHeight: CGFloat
    let sourceBoardWidth: CGFloat
    let targetBoardWidth: CGFloat

    static func resolved(
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        safeAreaInsets: EdgeInsets,
        grid: BoardGridMetrics
    ) -> BoardLayout {
        let key = CacheKey(
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            safeAreaInsets: safeAreaInsets,
            grid: grid
        )

        if let cached = cache[key] {
            PerfLog.log("BoardLayout cache hit for \(grid.sourceRows)x\(grid.sourceColumns)/\(grid.targetRows)x\(grid.targetColumns).")
            return cached
        }

        let layout = BoardLayout(
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            safeAreaInsets: safeAreaInsets,
            grid: grid
        )
        cache[key] = layout
        PerfLog.log("BoardLayout cache miss; created for \(grid.sourceRows)x\(grid.sourceColumns)/\(grid.targetRows)x\(grid.targetColumns).")
        return layout
    }

    init(availableWidth: CGFloat, availableHeight: CGFloat, safeAreaInsets: EdgeInsets, grid: BoardGridMetrics) {
        self.grid = grid
        let isExpandedLayout = availableWidth >= BoardUI.expandedLayoutMinWidth
        let usableWidth = max(
            availableWidth - safeAreaInsets.leading - safeAreaInsets.trailing - (BoardUI.horizontalPadding * 2),
            220
        )

        let usableHeight = max(
            availableHeight - safeAreaInsets.top - safeAreaInsets.bottom - BoardUI.topPadding - BoardUI.bottomPadding,
            320
        )

        let maxContentWidth = isExpandedLayout ? BoardUI.expandedMaxContentWidth : BoardUI.compactMaxContentWidth
        contentWidth = min(usableWidth, maxContentWidth)

        let sectionSpacingTotal = BoardUI.sectionSpacing * 4
        let sectionHeightBudget = max(
            usableHeight - BoardUI.titleBarHeight - BoardUI.titleBarHeight - sectionSpacingTotal,
            180
        )
        let minimumSectionHeights = [
            BoardUI.minimumSourceSectionHeight,
            BoardUI.minimumTargetSectionHeight,
            BoardUI.minimumCriteriaSectionHeight
        ]
        let sectionWeights = [
            BoardUI.sourceSectionWeight,
            BoardUI.targetSectionWeight,
            BoardUI.criteriaSectionWeight
        ]

        let minimumTotal = minimumSectionHeights.reduce(0, +)

        let baseSourceSectionHeight: CGFloat
        let baseTargetSectionHeight: CGFloat
        let baseCriteriaSectionHeight: CGFloat

        if sectionHeightBudget >= minimumTotal {
            let extraHeight = sectionHeightBudget - minimumTotal
            let weightTotal = sectionWeights.reduce(0, +)
            baseSourceSectionHeight = minimumSectionHeights[0] + (extraHeight * (sectionWeights[0] / weightTotal))
            baseTargetSectionHeight = minimumSectionHeights[1] + (extraHeight * (sectionWeights[1] / weightTotal))
            baseCriteriaSectionHeight = minimumSectionHeights[2] + (extraHeight * (sectionWeights[2] / weightTotal))
        } else {
            let scale = sectionHeightBudget / max(minimumTotal, 1)
            baseSourceSectionHeight = minimumSectionHeights[0] * scale
            baseTargetSectionHeight = minimumSectionHeights[1] * scale
            baseCriteriaSectionHeight = minimumSectionHeights[2] * scale
        }

        func boardWidth(tileSize: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
            (tileSize * CGFloat(columns)) + (spacing * CGFloat(columns - 1))
        }

        func tileSize(forWidth width: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
            (width - (spacing * CGFloat(columns - 1))) / CGFloat(columns)
        }

        func sourceHeightFit(_ sectionHeight: CGFloat) -> CGFloat {
            (sectionHeight - (CGFloat(grid.sourceRows - 1) * BoardUI.sourceTileRowSpacing)) / CGFloat(grid.sourceRows)
        }

        func targetHeightFit(_ sectionHeight: CGFloat) -> CGFloat {
            (sectionHeight - (CGFloat(grid.targetRows - 1) * BoardUI.targetRowSeparatorHeight)) / CGFloat(grid.targetRows)
        }

        func criteriaHeightCap(forSharedWidth width: CGFloat) -> CGFloat {
            let rowCount = BoardUI.criteriaCount
            let tabsWidth = max(40, width - (BoardUI.criteriaHorizontalInset * 2))
            return max(
                40,
                (tabsWidth - (BoardUI.criteriaTabSpacing * CGFloat(rowCount - 1))) / CGFloat(rowCount)
            )
        }

        let minSourceBoardWidth = boardWidth(
            tileSize: BoardUI.minimumSourceTileSize,
            columns: grid.sourceColumns,
            spacing: BoardUI.sourceTileSpacing
        )
        let minTargetBoardWidth = boardWidth(
            tileSize: BoardUI.minimumTargetTileSize,
            columns: grid.targetColumns,
            spacing: BoardUI.targetTileHorizontalSpacing
        )
        let minimumSharedWidthValue = max(minSourceBoardWidth, minTargetBoardWidth)
        minimumSharedWidth = minimumSharedWidthValue

        var solvedSourceSectionHeight = baseSourceSectionHeight
        var solvedTargetSectionHeight = baseTargetSectionHeight
        var solvedCriteriaSectionHeight = baseCriteriaSectionHeight
        let sourceTargetWeight = max(sectionWeights[0] + sectionWeights[1], 0.0001)

        for _ in 0..<4 {
            let sourceBoardWidthAtHeightLimit = boardWidth(
                tileSize: sourceHeightFit(solvedSourceSectionHeight),
                columns: grid.sourceColumns,
                spacing: BoardUI.sourceTileSpacing
            )
            let targetBoardWidthAtHeightLimit = boardWidth(
                tileSize: targetHeightFit(solvedTargetSectionHeight),
                columns: grid.targetColumns,
                spacing: BoardUI.targetTileHorizontalSpacing
            )
            let candidateSharedWidth = max(
                minimumSharedWidthValue,
                min(contentWidth, sourceBoardWidthAtHeightLimit, targetBoardWidthAtHeightLimit)
            )
            let criteriaCap = criteriaHeightCap(forSharedWidth: candidateSharedWidth)

            guard solvedCriteriaSectionHeight > criteriaCap else { break }

            let reclaimedHeight = solvedCriteriaSectionHeight - criteriaCap
            solvedCriteriaSectionHeight = criteriaCap
            solvedSourceSectionHeight += reclaimedHeight * (sectionWeights[0] / sourceTargetWeight)
            solvedTargetSectionHeight += reclaimedHeight * (sectionWeights[1] / sourceTargetWeight)
        }

        sourceSectionHeight = solvedSourceSectionHeight
        targetSectionHeight = solvedTargetSectionHeight
        criteriaSectionHeight = solvedCriteriaSectionHeight

        let finalSourceBoardWidthAtHeightLimit = boardWidth(
            tileSize: sourceHeightFit(sourceSectionHeight),
            columns: grid.sourceColumns,
            spacing: BoardUI.sourceTileSpacing
        )
        let finalTargetBoardWidthAtHeightLimit = boardWidth(
            tileSize: targetHeightFit(targetSectionHeight),
            columns: grid.targetColumns,
            spacing: BoardUI.targetTileHorizontalSpacing
        )
        sharedStackWidth = max(
            minimumSharedWidthValue,
            min(contentWidth, finalSourceBoardWidthAtHeightLimit, finalTargetBoardWidthAtHeightLimit)
        )

        let sourceTileSizeFitted = min(
            sourceHeightFit(sourceSectionHeight),
            tileSize(
                forWidth: sharedStackWidth,
                columns: grid.sourceColumns,
                spacing: BoardUI.sourceTileSpacing
            )
        )
        sourceTileSize = max(BoardUI.minimumSourceTileSize, sourceTileSizeFitted)

        let targetTileSizeFitted = min(
            targetHeightFit(targetSectionHeight),
            tileSize(
                forWidth: sharedStackWidth,
                columns: grid.targetColumns,
                spacing: BoardUI.targetTileHorizontalSpacing
            )
        )
        targetTileSize = max(BoardUI.minimumTargetTileSize, targetTileSizeFitted)

        sourceBoardHeight = (sourceTileSize * CGFloat(grid.sourceRows))
            + (BoardUI.sourceTileRowSpacing * CGFloat(max(grid.sourceRows - 1, 0)))

        sourceBoardWidth = boardWidth(
            tileSize: sourceTileSize,
            columns: grid.sourceColumns,
            spacing: BoardUI.sourceTileSpacing
        )
        targetBoardWidth = boardWidth(
            tileSize: targetTileSize,
            columns: grid.targetColumns,
            spacing: BoardUI.targetTileHorizontalSpacing
        )
    }
}

struct ContentView: View {
    private enum Screen {
        case levels
        case loading
        case game
    }

    private enum ActivePopup: String, Identifiable {
        case settings
        case gameInfo
        case levelNote
        case stats
        case splitVictory
        case perfectSplitVictory
        case about

        var id: String { rawValue }
    }

    enum PreviewPopup {
        case gameplay
        case splitMet
        case settings
        case intro
        case stats
        case victory
    }

    private struct SharePayload: Identifiable {
        let id = UUID()
        let message: String
    }

    private enum LevelTileStatus {
        case unfinished
        case split
        case perfectSplit

        var sealAssetName: String {
            switch self {
            case .unfinished:
                return "SealEmpty"
            case .split:
                return "SealSolid"
            case .perfectSplit:
                return "SealOffsetBorder"
            }
        }
    }

    private enum CriteriaMilestone: Hashable {
        case split
        case perfectSplit

        var sealColor: Color {
            switch self {
            case .split:
                return AppColor.split
            case .perfectSplit:
                return AppColor.perfectSplit
            }
        }

        func isVisible(hasAchievedSplit: Bool) -> Bool {
            switch self {
            case .split:
                return !hasAchievedSplit
            case .perfectSplit:
                return hasAchievedSplit
            }
        }

        func isAchieved(hasAchievedSplit: Bool, hasAchievedPerfectSplit: Bool) -> Bool {
            switch self {
            case .split:
                return hasAchievedSplit
            case .perfectSplit:
                return hasAchievedPerfectSplit
            }
        }
    }

    private struct CriteriaRowState {
        let kind: CriteriaMilestone
        let label: String?
        let goldWord: String?
        let goldLetterMatches: [Bool]?
        let isSatisfied: Bool
        let isMet: Bool
        let arePriorCriteriaMet: Bool
    }

    private static let levelDateCalendar = Calendar(identifier: .gregorian)
    private static var levelContent = LevelContentStore.loadStartupSnapshot(calendar: levelDateCalendar)
    private static var cachedActiveLevels: [LevelDefinition] = levelContent.activeLevels()
    private static var cachedDailyScheduleDateByLevelID: [String: Date] = levelContent.schedule.dateByLevelID
    private static var cachedBoardGrid: BoardGridMetrics = BoardGridMetrics(levels: cachedActiveLevels)
    private static var activeLevels: [LevelDefinition] { cachedActiveLevels }
    private static var dailyScheduleDateByLevelID: [String: Date] { cachedDailyScheduleDateByLevelID }
    private static let criteriaRules = CriteriaRuleLoader.loadRuleSet()
    private static let monthNamesUpper = [
        "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
        "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"
    ]
    private static let levelSubtitleWeekdayStyle = Date.FormatStyle
        .dateTime
        .weekday(.wide)
    private static let levelSubtitleMonthStyle = Date.FormatStyle
        .dateTime
        .month(.wide)
    private static let ordinalNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
    private static let maxUndoMovesPerLevel = 20
    private static let hasShownInfoPopupStorageKey = "split-happens.game-info-popup-shown.v1"
    private static let soundEnabledStorageKey = "split-happens.sound-enabled.v1"
    private static let hapticsEnabledStorageKey = "split-happens.haptics-enabled.v1"
    private static let shuffleAllLettersStorageKey = "split-happens.shuffle-all-letters.v1"
    private static let shuffleGoldTilesStorageKey = "split-happens.shuffle-gold-tiles.v1"
    private static let gameplayPreviewLevelID = "st-louis"
    private static let dropDiagnosticsEnvKey = "SPLIT_HAPPENS_DROP_DIAGNOSTICS"

    @State private var game = GameState(
        sourceWords: ContentView.activeLevels[0].startingWords,
        targetRowSizes: ContentView.activeLevels[0].boardShape.targetRowLengths,
        goldTileExpectations: ContentView.activeLevels[0].goldTileExpectations
    )
    @State private var currentLevelIndex = 0
    @State private var selectedLetterID: UUID?
    @State private var selectedTargetSlotID: UUID?
    @State private var draggingLetterID: UUID?
    @State private var hoveredTargetSlotID: UUID?
    @State private var previewTargetSlotID: UUID?
    @State private var previewSourceLetterID: UUID?
    @State private var previewDelayTask: Task<Void, Never>?
    @State private var dropHoverOutlineOpacity: Double = 0
    @State private var dropHoverOutlineTask: Task<Void, Never>?
    @State private var lastTargetTapSlotID: UUID?
    @State private var lastTargetTapTimestamp: TimeInterval = 0
    @State private var lastSourceTapLetterID: UUID?
    @State private var lastSourceTapTimestamp: TimeInterval = 0
    @State private var dragPosition: CGPoint = .zero
    @State private var dragOverlayScale: CGFloat = 1
    @State private var activeDragStartTimestamp: TimeInterval?
    @State private var pickupForceByLetterID: [UUID: CGFloat] = [:]
    @State private var slotFrames: [UUID: CGRect] = [:]
    @State private var sourceFrames: [UUID: CGRect] = [:]
    @State private var sourceGridFrame: CGRect = .null
    @State private var targetGridFrame: CGRect = .null
    @State private var validRows: Set<Int> = []
    @State private var cachedCompletedRowWords: [String?] = []
    @State private var cachedCriteriaRowWords: [String?] = []
    @State private var cachedGoldLetterMatches: [Bool] = []
    @State private var progressSnapshot: PersistedGameProgress = LocalProgressStorage.load()
    @State private var remoteRefreshTask: Task<Void, Never>?
    @State private var hasStartedRemoteRefresh = false
    @State private var levelContentRevision: Int = 0
    @State private var suspendLastPlayedWritesUntilTransitionEnd = false
    @State private var currentScreen: Screen = .levels
    @State private var isScreenTransitioning = false
    @State private var transitionCleanupTask: Task<Void, Never>?
    @State private var pendingLevelLoadTask: Task<Void, Never>?
    @State private var areLevelVisualsRevealed = false
    @State private var levelRevealTask: Task<Void, Never>?
    @State private var hasAchievedSplit = false
    @State private var hasAchievedPerfectSplit = false
    @State private var hintedRowIndices: Set<Int> = []
    @State private var moveHistoryByLevelID: [String: [[PersistedTilePlacement]]] = [:]
    @State private var earnedBadgesByLevelID: [String: Set<LevelAchievementBadge>] = [:]
    @State private var didRestorePersistedProgress = false
    @State private var activePopup: ActivePopup?
    @State private var popupDetentHeights: [ActivePopup: CGFloat] = [:]
    @State private var shouldSuppressMilestonePopups = false
    @State private var sharePayload: SharePayload?
    @State private var pendingShareMessage: String?
    @State private var levelOpenTraceStartTime: CFAbsoluteTime?
    @State private var levelOpenTraceLevelID: String?
    @State private var firstRenderLoggedLevelID: String?
    @State private var debouncedProgressSaveTask: Task<Void, Never>?
    @State private var isSoundEnabled = UserDefaults.standard.object(forKey: ContentView.soundEnabledStorageKey) as? Bool ?? true
    @State private var isHapticsEnabled = UserDefaults.standard.object(forKey: ContentView.hapticsEnabledStorageKey) as? Bool ?? true
    @State private var shuffleUsesAllLetters = UserDefaults.standard.object(
        forKey: ContentView.shuffleAllLettersStorageKey
    ) as? Bool ?? false
    @State private var shuffleIncludesCorrectGoldTiles = UserDefaults.standard.object(
        forKey: ContentView.shuffleGoldTilesStorageKey
    ) as? Bool ?? false

    private let screenTransitionDuration: Double = 0.5
    private var screenTransitionAnimation: Animation {
        .easeInOut(duration: screenTransitionDuration)
    }
    private let levelRevealDuration: Double = 0.22
    private let tapMovementThreshold: CGFloat = 3
    private let pickupForceThreshold: CGFloat = 0.18
    private let pickupMovementThreshold: CGFloat = 3
    private let targetDoubleTapMaxInterval: TimeInterval = 0.30
    private let downwardReturnSpeedThreshold: CGFloat = 900
    private let downwardReturnPredictedSpeedMultiplier: CGFloat = 1.08
    private let draggedTileGhostYOffset: CGFloat = -38
    private let draggedTileGhostScale: CGFloat = 1.08
    private let draggedTileUnderFingerOpacity: Double = 0.22
    private let draggedTileGhostOpacity: Double = 0.92
    private let targetDropHitboxExpansion: CGFloat = 22
    private let sourceDropHitboxExpansion: CGFloat = 20
    private let boardSpace = "board"
    @Environment(\.scenePhase) private var scenePhase
    private var isDropDiagnosticsEnabled: Bool {
        ProcessInfo.processInfo.environment[Self.dropDiagnosticsEnvKey] == "1"
    }

    init(previewShowVictoryPopup: Bool = false, previewPopup: PreviewPopup? = nil) {
        let resolvedPreviewPopup: PreviewPopup?
        if previewShowVictoryPopup {
            resolvedPreviewPopup = .victory
        } else {
            resolvedPreviewPopup = previewPopup
        }

        if let resolvedPreviewPopup {
            _didRestorePersistedProgress = State(initialValue: true)

            switch resolvedPreviewPopup {
            case .gameplay:
                let previewLevelIndex = Self.activeLevels.firstIndex { $0.id == Self.gameplayPreviewLevelID } ?? 0
                let previewLevel = Self.activeLevels[previewLevelIndex]
                let previewGame = GameState(
                    sourceWords: previewLevel.startingWords,
                    targetRowSizes: previewLevel.boardShape.targetRowLengths,
                    goldTileExpectations: previewLevel.goldTileExpectations
                )
                _currentLevelIndex = State(initialValue: previewLevelIndex)
                _game = State(initialValue: previewGame)
                _validRows = State(initialValue: Set(previewGame.slotIDs.indices.filter { previewGame.isRowValid($0) }))
                _currentScreen = State(initialValue: .game)
                _areLevelVisualsRevealed = State(initialValue: true)
                _activePopup = State(initialValue: nil)
            case .splitMet:
                let previewLevelIndex = Self.activeLevels.firstIndex { $0.id == Self.gameplayPreviewLevelID } ?? 0
                let previewLevel = Self.activeLevels[previewLevelIndex]
                let previewGame = GameState(
                    sourceWords: previewLevel.startingWords,
                    targetRowSizes: previewLevel.boardShape.targetRowLengths,
                    goldTileExpectations: previewLevel.goldTileExpectations
                )
                _currentLevelIndex = State(initialValue: previewLevelIndex)
                _game = State(initialValue: previewGame)
                _cachedCriteriaRowWords = State(initialValue: previewGame.slotIDs.indices.map(previewGame.criteriaWordForRow))
                _cachedGoldLetterMatches = State(initialValue: previewGame.goldLetterMatchesInOrder())
                _hasAchievedSplit = State(initialValue: true)
                _currentScreen = State(initialValue: .game)
                _areLevelVisualsRevealed = State(initialValue: true)
                _activePopup = State(initialValue: nil)
            case .settings:
                _currentScreen = State(initialValue: .levels)
                _activePopup = State(initialValue: .settings)
            case .intro:
                _currentScreen = State(initialValue: .levels)
                _activePopup = State(initialValue: .gameInfo)
            case .stats:
                _currentScreen = State(initialValue: .levels)
                _activePopup = State(initialValue: .stats)
            case .victory:
                let previewLevelIndex = Self.activeLevels.firstIndex { $0.id == Self.gameplayPreviewLevelID } ?? 0
                let previewLevel = Self.activeLevels[previewLevelIndex]
                _currentScreen = State(initialValue: .game)
                _currentLevelIndex = State(initialValue: previewLevelIndex)
                _game = State(initialValue: GameState(
                    sourceWords: previewLevel.startingWords,
                    targetRowSizes: previewLevel.boardShape.targetRowLengths,
                    goldTileExpectations: previewLevel.goldTileExpectations
                ))
                _hasAchievedSplit = State(initialValue: true)
                _hasAchievedPerfectSplit = State(initialValue: true)
                _earnedBadgesByLevelID = State(initialValue: [
                    previewLevel.id: Set(LevelAchievementBadge.allCases)
                ])
                _activePopup = State(initialValue: .perfectSplitVictory)
            }
        }
    }

    var body: some View {
        rootViewWithChangeHandlers
    }

    private var rootGeometryView: some View {
        GeometryReader { geometry in
            let layout = BoardLayout.resolved(
                availableWidth: geometry.size.width,
                availableHeight: geometry.size.height,
                safeAreaInsets: geometry.safeAreaInsets,
                grid: currentBoardGrid
            )
            let isShowingLevels = currentScreen == .levels
            let shouldRenderBothPanes = isShowingLevels || isScreenTransitioning
            let paneWidth = geometry.size.width
            let subtitleFontSize = criteriaLabelSize(for: layout) * 0.8 + 6
            let homeTitleStackHeight = titleStackHeight(showBackButton: false, subtitleFontSize: subtitleFontSize)

            ZStack {
                AppColor.boardBackground.ignoresSafeArea()

                if shouldRenderBothPanes {
                    levelsLandingView(geometry: geometry, titleStackHeight: homeTitleStackHeight)
                        .frame(width: paneWidth, height: geometry.size.height)
                        .compositingGroup()
                        .offset(x: isShowingLevels ? 0 : -paneWidth)
                        .allowsHitTesting(isShowingLevels)

                    levelPaneView(layout: layout, geometry: geometry)
                        .frame(width: paneWidth, height: geometry.size.height)
                        .compositingGroup()
                        .offset(x: isShowingLevels ? paneWidth : 0)
                        .allowsHitTesting(!isShowingLevels)
                } else {
                    levelPaneView(layout: layout, geometry: geometry)
                        .frame(width: paneWidth, height: geometry.size.height)
                        .compositingGroup()
                }

                sharedHeader(
                    in: geometry,
                    showBackButton: !isShowingLevels,
                    subtitle: isShowingLevels ? nil : (levelSubtitle(for: currentLevelIndex) ?? levelDisplayLabel(for: currentLevelIndex)),
                    criteriaLabelSize: subtitleFontSize
                )

                safeAreaDebugBorder(in: geometry)
                    .allowsHitTesting(false)

            }
        }
        .id(levelContentRevision)
    }

    private var rootViewWithPreferences: some View {
        rootGeometryView
        .coordinateSpace(name: boardSpace)
        .onPreferenceChange(SourceGridFrameKey.self) { frame in
            guard draggingLetterID == nil else { return }
            guard sourceGridFrame != frame else { return }
            sourceGridFrame = frame
            refreshBoardFrames()
        }
        .onPreferenceChange(TargetGridFrameKey.self) { frame in
            guard draggingLetterID == nil else { return }
            guard targetGridFrame != frame else { return }
            targetGridFrame = frame
            refreshBoardFrames()
        }
    }

    private var rootViewWithLifecycle: some View {
        rootViewWithPreferences
        .onAppear {
            beginRemoteRefresh()

            guard !didRestorePersistedProgress else {
                refreshBoardFrames()
                return
            }

            didRestorePersistedProgress = true
            restorePersistedProgressOnLaunch()
            presentGameInfoPopupIfNeeded()
        }
        .onDisappear {
            remoteRefreshTask?.cancel()
            remoteRefreshTask = nil
            debouncedProgressSaveTask?.cancel()
            debouncedProgressSaveTask = nil
            transitionCleanupTask?.cancel()
            transitionCleanupTask = nil
            pendingLevelLoadTask?.cancel()
            pendingLevelLoadTask = nil
            levelRevealTask?.cancel()
            levelRevealTask = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                PerfLog.log("Foreground refresh trigger.")
                remoteRefreshTask?.cancel()
                remoteRefreshTask = Task {
                    await refreshRemoteLevelsInBackground()
                }
            case .inactive:
                remoteRefreshTask?.cancel()
                transitionCleanupTask?.cancel()
                pendingLevelLoadTask?.cancel()
                levelRevealTask?.cancel()
            case .background:
                remoteRefreshTask?.cancel()
                transitionCleanupTask?.cancel()
                pendingLevelLoadTask?.cancel()
                levelRevealTask?.cancel()
                // Avoid heavy synchronous serialization on termination path.
                // Frequent saves already happen during gameplay; here we persist lightweight screen state only.
                persistCurrentScreen()
            @unknown default:
                remoteRefreshTask?.cancel()
                transitionCleanupTask?.cancel()
                pendingLevelLoadTask?.cancel()
                levelRevealTask?.cancel()
            }
        }
    }

    private var rootViewWithSheets: some View {
        rootViewWithLifecycle
        .sheet(item: $sharePayload) { payload in
            ShareSheet(activityItems: [payload.message])
        }
        .sheet(item: $activePopup, onDismiss: handlePopupDismiss) { popup in
            popupSheetView(for: popup)
        }
    }

    private var rootViewWithChangeHandlers: some View {
        rootViewWithSheets
        .onChange(of: activePopup) { _, popup in
            handleActivePopupChange(popup)
        }
        .onChange(of: previewTargetSlotID) { _, slotID in
            scheduleDropHoverOutlineAnimation(for: slotID ?? previewSourceLetterID)
        }
        .onChange(of: previewSourceLetterID) { _, letterID in
            scheduleDropHoverOutlineAnimation(for: previewTargetSlotID ?? letterID)
        }
    }

    @ViewBuilder
    private func popupSheetView(for popup: ActivePopup) -> some View {
        popupSheetContent(for: popup)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(sheetHeightPreferenceBackground)
            .onPreferenceChange(PopupSheetHeightKey.self) { measuredHeight in
                updatePopupDetentHeight(for: popup, measuredHeight: measuredHeight)
            }
            .presentationDetents([
                .height(preferredPopupDetentHeight(for: popup))
            ])
            .presentationDragIndicator(.hidden)
            .presentationBackground(AppColor.boardBackground)
            .background(AppColor.boardBackground)
    }

    private var sheetHeightPreferenceBackground: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: PopupSheetHeightKey.self, value: proxy.size.height)
        }
    }

    private func updatePopupDetentHeight(for popup: ActivePopup, measuredHeight: CGFloat) {
        let baseMaxHeight = currentSceneScreenHeight() * 0.92
        let maxHeight = popup == .stats ? baseMaxHeight + 50 : baseMaxHeight
        let clampedHeight = max(200, min(measuredHeight, maxHeight))

        if let existing = popupDetentHeights[popup] {
            if abs(clampedHeight - existing) > 1 {
                popupDetentHeights[popup] = clampedHeight
            }
        } else {
            popupDetentHeights[popup] = clampedHeight
        }
    }

    private func handleActivePopupChange(_ popup: ActivePopup?) {
        switch popup {
        case .splitVictory, .perfectSplitVictory:
            playVictorySound()
        default:
            break
        }
    }

    private func currentSceneScreenHeight() -> CGFloat {
        let sceneHeight = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map { $0.screen.bounds.height }
            .first

        return sceneHeight ?? 926
    }

    private func preferredPopupDetentHeight(for popup: ActivePopup) -> CGFloat {
        if popup == .settings {
            return 600
        }
        if popup == .about {
            return 500
        }
        return popupDetentHeights[popup] ?? 420
    }

    private func sharedHeader(
        in geometry: GeometryProxy,
        showBackButton: Bool,
        subtitle: String?,
        criteriaLabelSize: CGFloat
    ) -> some View {
        let safeWidth = max(
            geometry.size.width - geometry.safeAreaInsets.leading - geometry.safeAreaInsets.trailing - (BoardUI.horizontalPadding * 2),
            220
        )
        let headerWidth = min(safeWidth, BoardUI.compactMaxContentWidth)
        let subtitleFontSize = criteriaLabelSize
        let bottomBuffer = titleStackBottomBuffer(showBackButton: showBackButton, subtitleFontSize: subtitleFontSize)
        let subtitleRowHeight = showBackButton ? max(BoardUI.gameHeaderBottomMargin, subtitleFontSize + 16) : 0
        let topBackdropHeight = BoardUI.titleBarHeight + geometry.safeAreaInsets.top + subtitleRowHeight + bottomBuffer

        return ZStack(alignment: .top) {
            AppColor.criteriaGold
                .frame(maxWidth: .infinity)
                .frame(height: topBackdropHeight)
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 0) {
                titleBar(showBackButton: showBackButton)
                    .frame(maxWidth: .infinity)
                    .frame(height: BoardUI.titleBarHeight)
                if showBackButton {
                    ZStack {
                        if let subtitle {
                            HStack(spacing: 4) {
                                Text(subtitle)
                                    .font(.system(size: subtitleFontSize, weight: .semibold))
                                    .foregroundStyle(AppColor.textDefault)
                                    .lineLimit(1)

                                if currentScreen == .game, currentLevelNote != nil {
                                    Button {
                                        activePopup = .levelNote
                                    } label: {
                                        Image(systemName: "info.circle")
                                            .font(.system(size: subtitleFontSize, weight: .bold))
                                            .foregroundStyle(AppColor.textDefault)
                                    }
                                    .padding(8)
                                    .contentShape(Rectangle())
                                    .padding(-8)
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(width: headerWidth)
                        }
                    }
                    .frame(minHeight: subtitleRowHeight)
                }
                Color.clear
                    .frame(height: bottomBuffer)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, BoardUI.topPadding)
        }
        .animation(screenTransitionAnimation, value: showBackButton)
    }

    @MainActor
    private func beginRemoteRefresh() {
        guard !hasStartedRemoteRefresh else { return }
        hasStartedRemoteRefresh = true
        remoteRefreshTask?.cancel()
        remoteRefreshTask = Task {
            await refreshRemoteLevelsInBackground()
        }
    }

    @MainActor
    private func refreshRemoteLevelsInBackground() async {
        PerfLog.log("Firebase/cache refresh start.")
        let currentSnapshot = Self.levelContent
        guard let updatedSnapshot = await LevelContentStore.fetchRemoteSnapshotIfNewer(
            current: currentSnapshot,
            calendar: Self.levelDateCalendar
        ) else {
            PerfLog.log("Firebase/cache refresh finished with no update.")
            return
        }

        guard !Task.isCancelled else { return }
        applyRemoteLevelUpdate(updatedSnapshot)
        PerfLog.log("Firebase/cache refresh applied new snapshot.")
    }

    @MainActor
    private func applyRemoteLevelUpdate(_ updatedSnapshot: LevelContentSnapshot) {
        let previousLevelID = Self.activeLevels.indices.contains(currentLevelIndex)
            ? Self.activeLevels[currentLevelIndex].id
            : nil

        Self.levelContent = updatedSnapshot
        Self.cachedActiveLevels = updatedSnapshot.activeLevels()
        Self.cachedDailyScheduleDateByLevelID = updatedSnapshot.schedule.dateByLevelID
        Self.cachedBoardGrid = BoardGridMetrics(levels: Self.cachedActiveLevels)
        levelContentRevision &+= 1

        guard !Self.activeLevels.isEmpty else {
            return
        }

        let fallbackIndex = min(currentLevelIndex, Self.activeLevels.count - 1)
        let updatedLevelIndex = previousLevelID.flatMap { id in
            Self.activeLevels.firstIndex { $0.id == id }
        } ?? fallbackIndex

        if currentScreen == .game {
            loadLevel(at: updatedLevelIndex, restoreSavedProgress: true)
        } else {
            currentLevelIndex = updatedLevelIndex
            refreshBoardFrames()
        }
    }

    private var currentGameDate: Date {
        Self.levelDateCalendar.startOfDay(for: GameDateProvider.currentDate())
    }

    private var currentLevelNote: String? {
        guard Self.activeLevels.indices.contains(currentLevelIndex) else { return nil }
        let note = currentLevel.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? nil : note
    }

    private var releasedLevelIndices: [Int] {
        return Self.activeLevels.indices.filter { levelIndex in
            guard let releaseDate = levelDate(for: levelIndex) else {
                return false
            }
            return releaseDate <= currentGameDate
        }
    }

    private var homepageLevelIndices: [Int] {
        releasedLevelIndices
    }

    private var featuredLevelIndex: Int? {
        if let todayIndex = homepageLevelIndices.first(where: { levelIndex in
            guard let releaseDate = levelDate(for: levelIndex) else {
                return false
            }
            return Self.levelDateCalendar.isDate(releaseDate, inSameDayAs: currentGameDate)
        }) {
            return todayIndex
        }

        return homepageLevelIndices.last
    }

    private var remainingHomepageLevelIndices: [Int] {
        let newestFirst = Array(homepageLevelIndices.reversed())
        guard let featuredLevelIndex else {
            return newestFirst
        }

        return newestFirst.filter { $0 != featuredLevelIndex }
    }

    private func safeAreaDebugBorder(in geometry: GeometryProxy) -> some View {
        let insets = geometry.safeAreaInsets
        let safeWidth = max(0, geometry.size.width - insets.leading - insets.trailing)
        let safeHeight = max(0, geometry.size.height - insets.top - insets.bottom)

        return Rectangle()
            .stroke(Color.red, lineWidth: 0)
            .frame(width: safeWidth, height: safeHeight)
            .offset(x: insets.leading, y: insets.top)
    }

    private func titleBar(showBackButton: Bool) -> some View {
        HStack {
            if showBackButton {
                Button {
                    exitLevel()
                } label: {
                    Image(systemName: "arrow.backward")
                        .font(.system(size: BoardUI.titleBarNavIconSize * 0.8))
                        .foregroundStyle(AppColor.buttonActive)
                }
                .frame(width: BoardUI.navButtonWidth, alignment: .leading)
            } else {
                Button {
                    activePopup = .settings
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: BoardUI.titleBarNavIconSize * 0.8))
                        .foregroundStyle(AppColor.buttonActive)
                }
                .frame(width: BoardUI.navButtonWidth, alignment: .leading)
            }

            Image("Title")
                .resizable()
                .scaledToFit()
                .frame(height: BoardUI.titleFontSize * 1.8)
                .frame(maxWidth: .infinity)

            if showBackButton {
                Button {
                    resetSourceTilesToOriginalPositions()
                } label: {
                    Image(systemName: "arrow.trianglehead.counterclockwise")
                        .font(.system(size: BoardUI.titleBarNavIconSize * 0.8))
                        .foregroundStyle(AppColor.buttonActive)
                }
                .frame(width: BoardUI.navButtonWidth, alignment: .trailing)
            } else {
                Button {
                    activePopup = .stats
                } label: {
                    Image(systemName: "chart.bar")
                        .font(.system(size: BoardUI.titleBarNavIconSize * 0.8))
                        .foregroundStyle(AppColor.buttonActive)
                }
                .frame(width: BoardUI.navButtonWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, BoardUI.titleBarSidePadding)
    }

    private func levelsLandingView(geometry: GeometryProxy, titleStackHeight: CGFloat) -> some View {
        let horizontalPadding = BoardUI.horizontalPadding
        let safeWidth = max(
            geometry.size.width - geometry.safeAreaInsets.leading - geometry.safeAreaInsets.trailing - (horizontalPadding * 2),
            220
        )
        let stackWidth = min(safeWidth, BoardUI.compactMaxContentWidth)
        let horizontalSafeZone = stackWidth * 0.05
        let tileStackWidth = max(120, stackWidth - (horizontalSafeZone * 2))
        let tileSpacing = max(BoardUI.targetTileHorizontalSpacing * 2, 16)
        let gridTileSize = max(56, floor((tileStackWidth - (tileSpacing * 2)) / 3))
        let featuredTileSize = tileStackWidth
        let columns = Array(repeating: GridItem(.flexible(), spacing: tileSpacing), count: 3)
        let featuredLevel = featuredLevelIndex
        let remainingLevelIndices = remainingHomepageLevelIndices
        let levelProgressByID = progressSnapshot.levelsByID
        let topContentInset = BoardUI.topPadding + titleStackHeight + 20

        return VStack(spacing: BoardUI.sectionSpacing) {

            
            ScrollView {
                VStack(spacing: tileSpacing) {
                    
                    if let featuredLevel {
                        levelTileButton(
                            index: featuredLevel,
                            width: featuredTileSize,
                            height: featuredTileSize,
                            status: levelTileStatus(
                                for: Self.activeLevels[featuredLevel].id,
                                progressByLevelID: levelProgressByID
                            ),
                            isFeatured: true,
                            badges: levelBadges(
                                for: Self.activeLevels[featuredLevel].id,
                                progressByLevelID: levelProgressByID
                            )
                        )
                    }

                    LazyVGrid(columns: columns, spacing: tileSpacing) {
                        ForEach(remainingLevelIndices, id: \.self) { levelIndex in
                            levelTileButton(
                                index: levelIndex,
                                width: gridTileSize,
                                height: gridTileSize,
                                status: levelTileStatus(
                                    for: Self.activeLevels[levelIndex].id,
                                    progressByLevelID: levelProgressByID
                                ),
                                isFeatured: false,
                                badges: levelBadges(
                                    for: Self.activeLevels[levelIndex].id,
                                    progressByLevelID: levelProgressByID
                                )
                            )
                        }
                    }
                }
                .padding(.top, topContentInset)
                .padding(.bottom, geometry.safeAreaInsets.bottom + BoardUI.sectionSpacing)
                .frame(width: tileStackWidth)
                .frame(width: safeWidth, alignment: .top)
                .contentShape(Rectangle())
            }
            .frame(width: safeWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, horizontalPadding)
        .padding(.bottom, BoardUI.bottomPadding - geometry.safeAreaInsets.bottom)
    }

    private func levelLoadingView(layout: BoardLayout, geometry: GeometryProxy) -> some View {
        VStack(spacing: BoardUI.sectionSpacing) {
            Color.clear
                .frame(width: layout.sharedStackWidth)
                .frame(height: BoardUI.titleBarHeight + BoardUI.gameHeaderBottomMargin)

            Spacer(minLength: 0)

            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(AppColor.textDefault)
                    .scaleEffect(1.2)

                Text("Loading level...")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppColor.textDefault)
            }

            Spacer(minLength: 0)
        }
        .frame(width: layout.contentWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .padding(.top, BoardUI.topPadding)
        .padding(.horizontal, BoardUI.horizontalPadding)
        .padding(.bottom, geometry.safeAreaInsets.bottom + BoardUI.bottomPadding)
    }

    @ViewBuilder
    private func levelPaneView(layout: BoardLayout, geometry: GeometryProxy) -> some View {
        if currentScreen == .loading {
            levelLoadingView(layout: layout, geometry: geometry)
        } else {
            gameplayView(layout: layout, geometry: geometry)
                .onAppear {
                    logLevelOpen("LevelHostView appear")
                    let levelID = currentLevel.id
                    guard firstRenderLoggedLevelID != levelID else { return }
                    firstRenderLoggedLevelID = levelID
                    DispatchQueue.main.async {
                        logLevelOpen("first board render")
                    }
                }
        }
    }

    private func gameplayView(layout: BoardLayout, geometry: GeometryProxy) -> some View {
        let subtitleFontSize = criteriaLabelSize(for: layout)
        let gameTitleStackHeight = titleStackHeight(showBackButton: true, subtitleFontSize: subtitleFontSize)
        return ZStack {
            VStack(spacing: BoardUI.sectionSpacing) {
                Color.clear
                    .frame(width: layout.sharedStackWidth)
                    .frame(height: gameTitleStackHeight + 20)
                criteriaSection()
                .frame(width: layout.sharedStackWidth)
                .frame(height: layout.criteriaSectionHeight)
                Spacer()
                targetBoard(layout: layout)
                    .frame(width: layout.sharedStackWidth)
                    .frame(height: layout.targetSectionHeight, alignment: .bottom)
                Spacer()
                    .frame(maxHeight: 20)
                sourceBoard(layout: layout)
                    .frame(width: layout.sharedStackWidth)
                    .frame(height: layout.sourceBoardHeight, alignment: .top)
                Spacer()
                    .frame(maxHeight: 20)
                bottomActionBar
                    .frame(width: layout.sharedStackWidth - 20)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: layout.contentWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity)
            .padding(.top, BoardUI.topPadding)
            .padding(.horizontal, BoardUI.horizontalPadding)
            .contentShape(Rectangle())
            .simultaneousGesture(levelExitSwipeGesture(in: geometry))
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(boardSpace))
                    .onEnded { value in
                        handleBoardTapOutsideSwapArea(at: value.location)
                    }
            )

            if let id = draggingLetterID, let draggedLetter = game.letter(byID: id) {
                let tileSize = layout.targetTileSize
                let cornerRadius = tileSize * BoardUI.targetTileCornerRatio

                ZStack {
                    // Keep a faint under-finger tile for spatial continuity.
                    letterTileView(
                        draggedLetter.character,
                        size: tileSize,
                        cornerRadius: cornerRadius
                    )
                    .opacity(previewTargetSlotID == nil ? draggedTileUnderFingerOpacity : 0)
                    .scaleEffect(dragOverlayScale)
                    .position(dragPosition)

                    // Render a lifted ghost for visibility without affecting hit-testing.
                    letterTileView(
                        draggedLetter.character,
                        size: tileSize,
                        cornerRadius: cornerRadius
                    )
                    .opacity(previewTargetSlotID == nil ? draggedTileGhostOpacity : 0.55)
                    .scaleEffect(draggedTileGhostScale * dragOverlayScale)
                    .shadow(color: AppColor.selection.opacity(0.24), radius: 8, x: 0, y: 4)
                    .position(dragPosition)
                    .offset(y: draggedTileGhostYOffset)
                }
                .allowsHitTesting(false)
            }

            ShakeDetector {
                undoLastMove()
            }
            .frame(width: 0, height: 0)

            Color.clear
                .frame(
                    width: leftEdgeSwipeCaptureWidth(safeAreaInsets: geometry.safeAreaInsets),
                    height: geometry.size.height
                )
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .gesture(leftEdgeExitSwipeGesture(in: geometry))

        }
    }

    private func levelTileButton(
        index: Int,
        width: CGFloat,
        height: CGFloat,
        status: LevelTileStatus,
        isFeatured: Bool,
        badges: [LevelAchievementBadge]
    ) -> some View {
        let dayFontSize = max(18, min(width, height) * 0.24)
        let subheaderFontSize = criteriaLabelFontSize(for: height)
        let baseBadgeButtonSize = min(height * 0.2, 60)
        let badgeButtonSize = isFeatured ? baseBadgeButtonSize * 0.8 : baseBadgeButtonSize
        let badgeGap = height * 0.05
        let badgeYPosition = height * (isFeatured ? 0.78 : 0.82)

        return Button {
            enterLevel(at: index)
        } label: {
            ZStack {
                levelTileStatusSeal(status, size: min(width, height) * 0.9, isFeatured: isFeatured)

                levelTileLabel(
                    for: index,
                    dayFontSize: dayFontSize,
                    subheaderFontSize: subheaderFontSize,
                    isFeatured: isFeatured
                )
                    .foregroundStyle(AppColor.textDefault)
            }
            .frame(width: width, height: height)
            .overlay {
                if !badges.isEmpty {
                    HStack(spacing: badgeGap) {
                        ForEach(badges, id: \.rawValue) { badge in
                            Image(systemName: badge.systemImage)
                                .font(.system(size: badgeButtonSize * 0.85, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(AppColor.criteriaGold, AppColor.buttonActive)
                                .frame(width: badgeButtonSize, height: badgeButtonSize)
                        }
                    }
                    .position(x: width * 0.5, y: badgeYPosition)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func levelTileStatus(
        for levelID: String,
        progressByLevelID: [String: PersistedLevelProgress]
    ) -> LevelTileStatus {
        guard let persistedLevel = progressByLevelID[levelID] else {
            return .unfinished
        }

        if persistedLevel.hasAchievedPerfectSplit {
            return .perfectSplit
        }
        if persistedLevel.hasAchievedSplit {
            return .split
        }
        return .unfinished
    }

    private func levelTileStatusSeal(_ status: LevelTileStatus, size: CGFloat, isFeatured: Bool) -> some View {
        let offsetBorderExpansion: CGFloat = isFeatured ? 0 : 20
        let imageSize = status == .perfectSplit ? size + offsetBorderExpansion : size

        return Image(status.sealAssetName)
            .resizable()
            .scaledToFit()
            .frame(width: imageSize, height: imageSize)
            .frame(width: size, height: size)
    }

    private func levelBadges(
        for levelID: String,
        progressByLevelID: [String: PersistedLevelProgress]
    ) -> [LevelAchievementBadge] {
        guard let persistedLevel = progressByLevelID[levelID] else { return [] }
        let earned = Set(persistedLevel.earnedGoldBadges.compactMap(LevelAchievementBadge.init(rawValue:)))
        return LevelAchievementBadge.allCases.filter { earned.contains($0) }
    }

    @ViewBuilder
    private func levelTileLabel(
        for levelIndex: Int,
        dayFontSize: CGFloat,
        subheaderFontSize: CGFloat,
        isFeatured: Bool
    ) -> some View {
        if isFeatured {
            let (month, day) = featuredLevelDisplayLabel(for: levelIndex)
            VStack {
                Text(month)
                    .font(.system(size: subheaderFontSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .offset(y: dayFontSize * 0.2)
                Text(day)
                    .font(.system(size: dayFontSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        } else {
            let (month, day) = gridLevelDisplayLabel(for: levelIndex)
            let monthDayLineSpacing = -min(5, max(0.5, dayFontSize * 0.2))
            VStack(spacing: monthDayLineSpacing) {
                Text(month)
                    .font(.system(size: subheaderFontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(day)
                    .font(.system(size: dayFontSize * 1.1, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    private func levelDisplayLabel(for levelIndex: Int) -> String {
        guard let date = levelDate(for: levelIndex) else {
            return "\(levelIndex + 1)"
        }

        let components = Self.levelDateCalendar.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else {
            return "\(levelIndex + 1)"
        }

        return "\(month)/\(day)"
    }

    private func featuredLevelDisplayLabel(for levelIndex: Int) -> (month: String, day: String) {
        guard let date = levelDate(for: levelIndex) else {
            return ("", "\(levelIndex + 1)")
        }

        let monthIndex = Self.levelDateCalendar.component(.month, from: date) - 1
        let month = Self.monthNamesUpper.indices.contains(monthIndex) ? Self.monthNamesUpper[monthIndex] : ""
        let day = Self.levelDateCalendar.component(.day, from: date)
        return (month, "\(day)")
    }

    private func gridLevelDisplayLabel(for levelIndex: Int) -> (month: String, day: String) {
        let (month, day) = featuredLevelDisplayLabel(for: levelIndex)
        return (String(month.prefix(3)), day)
    }

    private func levelDate(for levelIndex: Int) -> Date? {
        guard Self.activeLevels.indices.contains(levelIndex) else {
            return nil
        }

        let levelID = Self.activeLevels[levelIndex].id
        return Self.dailyScheduleDateByLevelID[levelID]
    }

    private func levelSubtitle(for levelIndex: Int) -> String? {
        guard let date = levelDate(for: levelIndex) else {
            return nil
        }

        let weekday = date.formatted(Self.levelSubtitleWeekdayStyle)
        let month = date.formatted(Self.levelSubtitleMonthStyle)
        let dayNumber = Self.levelDateCalendar.component(.day, from: date)
        let dayWithOrdinal = Self.ordinalNumberFormatter.string(from: NSNumber(value: dayNumber)) ?? "\(dayNumber)"
        return "\(weekday), \(month) \(dayWithOrdinal)"
    }

    private var bottomActionBar: some View {
        HStack(spacing: 0) {
            bottomActionButton(systemImage: "questionmark.circle") {
                activePopup = .gameInfo
            }
            .offset(y: 0)
            
            bottomActionButton(systemImage: "lightbulb.circle.fill", iconSize: BoardUI.hintIconSize) {
                useHint()
            }
            .offset(y: 0)

            bottomActionButton(systemImage: "arrow.uturn.backward.circle", isEnabled: isUndoEnabled) {
                undoLastMove()
            }
            .offset(y: 0)


        }
    }

    private var isUndoEnabled: Bool {
        guard Self.activeLevels.indices.contains(currentLevelIndex) else { return false }

        let levelID = currentLevel.id
        var history = moveHistoryByLevelID[levelID] ?? []
        let currentPlacements = currentTilePlacementsForPersistence()

        guard !history.isEmpty else { return false }
        if history.last != currentPlacements {
            history.append(currentPlacements)
        }

        return history.count > 1
    }

    @ViewBuilder
    private func bottomActionButton(
        systemImage: String,
        isEnabled: Bool = true,
        foregroundColor: Color? = nil,
        xOffset: CGFloat = 0,
        indicatorDotColor: Color? = nil,
        indicatorDotXOffsetRatio: CGFloat = 0,
        indicatorDotYOffsetRatio: CGFloat = 0,
        indicatorDotSizeRatio: CGFloat = 0.15,
        iconSize: CGFloat = BoardUI.bottomActionBarIconSize,
        action: @escaping () -> Void = {}
    ) -> some View {
        let iconColor = foregroundColor ?? (isEnabled ? AppColor.buttonActive : AppColor.tilePlaceholder)
        let icon = Image(systemName: systemImage)
            .font(.system(size: iconSize))
            .foregroundStyle(iconColor)
            .offset(x: xOffset)
            .overlay {
                if let indicatorDotColor {
                    Circle()
                        .fill(indicatorDotColor)
                        .frame(
                            width: iconSize * indicatorDotSizeRatio,
                            height: iconSize * indicatorDotSizeRatio
                        )
                        .offset(
                            x: iconSize * indicatorDotXOffsetRatio,
                            y: iconSize * indicatorDotYOffsetRatio
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        if isEnabled {
            Button(action: action) {
                icon
            }
            .buttonStyle(.plain)
        } else {
            icon
        }
    }

    private func sourceBoard(layout: BoardLayout) -> some View {
        VStack(spacing: BoardUI.sourceTileRowSpacing) {
            ForEach(0..<layout.grid.sourceRows, id: \.self) { rowIndex in
                HStack(spacing: BoardUI.sourceTileSpacing) {
                    ForEach(0..<layout.grid.sourceColumns, id: \.self) { columnIndex in
                        sourceCell(
                            rowIndex: rowIndex,
                            columnIndex: columnIndex,
                            tileSize: layout.sourceTileSize
                        )
                    }
                }
            }
        }
        .frame(width: layout.sourceBoardWidth)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SourceGridFrameKey.self,
                    value: geometry.frame(in: .named(boardSpace))
                )
            }
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func sourceCell(rowIndex: Int, columnIndex: Int, tileSize: CGFloat) -> some View {
        let cornerRadius = tileSize * BoardUI.sourceTileCornerRatio
        if let sourceSlotID = game.sourceSlotID(wordIndex: rowIndex, columnIndex: columnIndex) {
            let isDropHoverSourceTile = previewSourceLetterID == sourceSlotID

            if let letter = game.letterInSourceSlot(sourceSlotID) {
                let isSelectedSourceTile = selectedLetterID == letter.id
                letterTileView(
                    letter.character,
                    size: tileSize,
                    cornerRadius: cornerRadius,
                    fillColor: areLevelVisualsRevealed ? AppColor.tileFill : AppColor.tilePlaceholder,
                    textOpacity: areLevelVisualsRevealed ? 1 : 0
                )
                    .opacity(draggingLetterID == letter.id ? 0 : 1)
                    .background {
                        if draggingLetterID == letter.id {
                            tileSurface(
                                cornerRadius: cornerRadius,
                                fill: areLevelVisualsRevealed ? AppColor.tileFill.opacity(0.2) : AppColor.tilePlaceholder,
                                shadowYOffset: 1
                            )
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(AppColor.selection, lineWidth: isSelectedSourceTile ? 3 : 0)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(
                                AppColor.selection.opacity(isDropHoverSourceTile ? dropHoverOutlineOpacity : 0),
                                lineWidth: 3
                            )
                    )
                    .background(
                        TileForceSensor { force in
                            updatePickupForce(force, for: letter.id)
                        }
                    )
                    .allowsHitTesting(draggingLetterID == nil || draggingLetterID == letter.id)
                    .gesture(tileDragGesture(for: letter))
            } else {
                tileSurface(
                    cornerRadius: cornerRadius,
                    fill: areLevelVisualsRevealed ? AppColor.tileFill.opacity(0.2) : AppColor.tilePlaceholder,
                    shadowYOffset: 1
                )
                    .frame(width: tileSize, height: tileSize)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(
                                AppColor.selection.opacity(isDropHoverSourceTile ? dropHoverOutlineOpacity : 0),
                                lineWidth: 3
                            )
                    )
                    .onTapGesture {
                        returnSelectedToSource(sourceSlotID: sourceSlotID)
                    }
            }
        } else {
            emptyGridCell(size: tileSize)
        }
    }

    private func targetBoard(layout: BoardLayout) -> some View {
        let dividerVerticalPadding = BoardUI.targetDividerVerticalPadding
        let activeTargetRowCount = game.slotIDs.count
        let visibleTargetRowCount = max(activeTargetRowCount, 1)

        return VStack(spacing: 0) {
            ForEach(0..<visibleTargetRowCount, id: \.self) { rowIndex in
                HStack(spacing: BoardUI.targetTileHorizontalSpacing) {
                    ForEach(0..<layout.grid.targetColumns, id: \.self) { columnIndex in
                        targetCell(rowIndex: rowIndex, columnIndex: columnIndex, tileSize: layout.targetTileSize)
                    }
                }

                if rowIndex < visibleTargetRowCount - 1 {
                    let shouldShowDivider = rowIndex < activeTargetRowCount - 1
                    Rectangle()
                        .fill(shouldShowDivider ? AppColor.textDefault.opacity(0.2) : .clear)
                        .frame(width: layout.targetBoardWidth, height: 1)
                        .padding(.vertical, dividerVerticalPadding)
                }
            }
        }
        .frame(width: layout.targetBoardWidth)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TargetGridFrameKey.self,
                    value: geometry.frame(in: .named(boardSpace))
                )
            }
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func targetCell(rowIndex: Int, columnIndex: Int, tileSize: CGFloat) -> some View {
        if game.slotIDs.indices.contains(rowIndex),
           game.slotIDs[rowIndex].indices.contains(columnIndex) {
            targetSlotView(
                slotID: game.slotIDs[rowIndex][columnIndex],
                rowIndex: rowIndex,
                tileSize: tileSize
            )
        } else {
            emptyGridCell(size: tileSize)
        }
    }

    private func criteriaSection() -> some View {
        let rowWords = cachedCriteriaRowWords.count == game.slotIDs.count
            ? cachedCriteriaRowWords
            : game.slotIDs.indices.map(game.criteriaWordForRow)
        let goldLetterMatches = cachedGoldLetterMatches
        let rows = criteriaRows(
            for: currentLevel,
            completedWords: validRows.count,
            totalWords: game.slotIDs.count,
            rowWords: rowWords,
            goldLetterMatches: goldLetterMatches
        )
        let visibleRows = rows.filter { row in
            row.kind.isVisible(hasAchievedSplit: hasAchievedSplit)
        }

        return GeometryReader { geometry in
            let rowCount = max(visibleRows.count, 1)
            let tabSpacing = BoardUI.criteriaTabSpacing
            let interTabCount = max(rowCount - 1, 0)
            let tabsWidth = max(40, geometry.size.width - (BoardUI.criteriaHorizontalInset * 2))
            let columnWidth = max(
                40,
                (tabsWidth - (tabSpacing * CGFloat(interTabCount))) / CGFloat(rowCount)
            )
            let tabHeight = min(geometry.size.height, columnWidth)
            let tabsYOffset = (geometry.size.height - tabHeight) * 0.5
            let preferredFontSize = criteriaLabelFontSize(for: tabHeight)

            ZStack(alignment: .topLeading) {
                HStack(spacing: tabSpacing) {
                    ForEach(visibleRows, id: \.kind) { row in
                        criteriaRow(
                            label: row.label,
                            goldWord: row.goldWord,
                            goldLetterMatches: row.goldLetterMatches,
                            width: columnWidth,
                            height: tabHeight,
                            preferredFontSize: preferredFontSize
                        )
                    }
                }
                .padding(.horizontal, BoardUI.criteriaHorizontalInset)
                .offset(y: tabsYOffset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func criteriaLabelFontSize(for height: CGFloat) -> CGFloat {
        max(11, min(22, height * 0.12))
    }

    private func titleStackBottomBuffer(showBackButton: Bool, subtitleFontSize: CGFloat) -> CGFloat {
        showBackButton ? (subtitleFontSize * 0.3) : subtitleFontSize
    }

    private func titleStackHeight(showBackButton: Bool, subtitleFontSize: CGFloat) -> CGFloat {
        let subtitleRowHeight = showBackButton ? max(BoardUI.gameHeaderBottomMargin, subtitleFontSize + 16) : 0
        return BoardUI.titleBarHeight + subtitleRowHeight + titleStackBottomBuffer(showBackButton: showBackButton, subtitleFontSize: subtitleFontSize)
    }

    private var currentLevel: LevelDefinition {
        Self.activeLevels[currentLevelIndex]
    }

    private func criteriaLabelSize(for layout: BoardLayout) -> CGFloat {
        let rowCount = BoardUI.criteriaCount
        let tabsWidth = max(40, layout.sharedStackWidth - (BoardUI.criteriaHorizontalInset * 2))
        let interTabCount = max(rowCount - 1, 0)
        let columnWidth = max(
            40,
            (tabsWidth - (BoardUI.criteriaTabSpacing * CGFloat(interTabCount))) / CGFloat(rowCount)
        )
        let tabHeight = min(layout.criteriaSectionHeight, columnWidth)
        return criteriaLabelFontSize(for: tabHeight)
    }

    private func criteriaRows(
        for level: LevelDefinition,
        completedWords: Int,
        totalWords: Int,
        rowWords: [String?],
        goldLetterMatches: [Bool]
    ) -> [CriteriaRowState] {
        let criteria: [(kind: CriteriaMilestone, rawCriterion: String)] = [
            (.split, level.criteriaRegular),
            (.perfectSplit, level.criteriaPerfect)
        ]

        var rows: [CriteriaRowState] = []
        var priorCriteriaSatisfied = true

        for definition in criteria {
            guard let criterion = LevelCriterion(rawValue: definition.rawCriterion) else {
                rows.append(CriteriaRowState(
                    kind: definition.kind,
                    label: nil,
                    goldWord: nil,
                    goldLetterMatches: nil,
                    isSatisfied: false,
                    isMet: false,
                    arePriorCriteriaMet: priorCriteriaSatisfied
                ))
                priorCriteriaSatisfied = false
                continue
            }

            let rawLabel = criterion.label(
                completedWords: completedWords,
                totalWords: totalWords,
                rules: Self.criteriaRules
            )
            let goldWord = perfectSplitCriterionWord(from: rawLabel)
            let label: String
            let rowGoldWord: String?
            switch definition.kind {
            case .split:
                label = "SPLIT ALL TILES INTO WORDS"
                rowGoldWord = nil
            case .perfectSplit:
                label = goldWord.map { "GOLD TILES MUST SPELL \($0) IN ORDER" } ?? rawLabel
                rowGoldWord = goldWord
            }
            let goldProgress = rowGoldWord.map { _ in goldLetterMatches }
            let isMet = goldProgress.map { matches in
                !matches.isEmpty && matches.allSatisfy { $0 }
            } ?? criterion.isSatisfied(
                completedWords: completedWords,
                totalWords: totalWords,
                rowWords: rowWords
            )
            let isSatisfied = priorCriteriaSatisfied && isMet

            rows.append(CriteriaRowState(
                kind: definition.kind,
                label: label,
                goldWord: rowGoldWord,
                goldLetterMatches: goldProgress,
                isSatisfied: isSatisfied,
                isMet: isMet,
                arePriorCriteriaMet: priorCriteriaSatisfied
            ))

            priorCriteriaSatisfied = isSatisfied
        }

        return rows
    }

    private func criteriaRow(
        label: String?,
        goldWord: String?,
        goldLetterMatches: [Bool]?,
        width: CGFloat,
        height: CGFloat,
        preferredFontSize: CGFloat
    ) -> some View {
        VStack(spacing: max(4, height * 0.05)) {
            if let label {
                let baseText = criteriaRowLabelText(
                    label: label,
                    goldWord: goldWord,
                    goldLetterMatches: goldLetterMatches
                )
                let goldPlacementAction: (() -> Void)? = {
                    guard goldWord != nil,
                          goldLetterMatches != nil else {
                        return nil
                    }
                    return { placeGoldTilesInCorrectOrder() }
                }()

                criteriaRowTextVariant(
                    baseText: baseText,
                    fontSize: preferredFontSize,
                    action: goldPlacementAction
                )
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, max(6, height * 0.05))
        .padding(.horizontal, 6)
        .frame(width: width, height: height)
        .background(Color.clear)
    }

    private func perfectSplitCriterionWord(from label: String) -> String? {
        let prefixes = [
            "GOLD TILES MUST SPELL ",
            "GOLD TILES SPELL "
        ]
        let suffix = " IN ORDER"

        guard let prefix = prefixes.first(where: { label.hasPrefix($0) }) else { return nil }
        var word = String(label.dropFirst(prefix.count))
        if word.hasSuffix(suffix) {
            word.removeLast(suffix.count)
        }
        return word
    }

    private func criteriaRowLabelText(label: String, goldWord: String?, goldLetterMatches: [Bool]?) -> Text {
        if let goldLetterMatches,
           let goldWord {
            return Text(perfectSplitCriteriaLabelAttributedString(
                label: label,
                word: goldWord,
                goldLetterMatches: goldLetterMatches
            ))
        }

        var attributed = AttributedString(label)
        attributed.foregroundColor = AppColor.criteriaLabel
        return Text(attributed)
    }

    private func perfectSplitCriteriaLabelAttributedString(
        label: String,
        word: String,
        goldLetterMatches: [Bool]
    ) -> AttributedString {
        var attributed = perfectSplitCriteriaPromptAttributedString()

        guard let wordRange = label.range(of: word) else {
            var labelText = AttributedString(label)
            labelText.foregroundColor = AppColor.criteriaLabel
            attributed.append(labelText)
            return attributed
        }

        var prefix = AttributedString(String(label[..<wordRange.lowerBound]))
        prefix.foregroundColor = AppColor.criteriaLabel
        attributed.append(prefix)

        for (index, character) in word.enumerated() {
            var letterText = AttributedString(String(character))
            let isCorrect = goldLetterMatches.indices.contains(index) && goldLetterMatches[index]
            letterText.foregroundColor = isCorrect ? AppColor.letterCorrect : AppColor.letterCorrect.opacity(0.5)
            attributed.append(letterText)
        }

        var suffix = AttributedString(String(label[wordRange.upperBound...]))
        suffix.foregroundColor = AppColor.criteriaLabel
        attributed.append(suffix)

        return attributed
    }

    private func perfectSplitCriteriaPromptAttributedString() -> AttributedString {
        var attributed = AttributedString("GO FOR ")
        attributed.foregroundColor = AppColor.criteriaLabel

        var perfect = AttributedString("PERFECT!")
        perfect.foregroundColor = AppColor.darkGold
        attributed.append(perfect)

        var suffix = AttributedString("\n")
        suffix.foregroundColor = AppColor.criteriaLabel
        attributed.append(suffix)

        return attributed
    }

    @ViewBuilder
    private func criteriaRowTextVariant(baseText: Text, fontSize: CGFloat, action: (() -> Void)? = nil) -> some View {
        let label = baseText
            .font(.system(size: fontSize, weight: .bold))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 8)

        if let action {
            Button(action: action) {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private func enterLevel(at index: Int) {
        let tappedLevelID = Self.activeLevels[index].id
        levelOpenTraceLevelID = tappedLevelID
        levelOpenTraceStartTime = CFAbsoluteTimeGetCurrent()
        logLevelOpen("tap level", detail: "id=\(tappedLevelID)")

        pendingLevelLoadTask?.cancel()
        levelRevealTask?.cancel()
        transitionCleanupTask?.cancel()
        areLevelVisualsRevealed = false
        suspendLastPlayedWritesUntilTransitionEnd = true

        // Prepare the entire game pane first with animations disabled so the
        // incoming pane can slide as a single frozen surface.
        var noAnimation = Transaction(animation: nil)
        noAnimation.disablesAnimations = true
        withTransaction(noAnimation) {
            logLevelOpen("snapshot lookup", detail: "levelIndex=\(index)")
            loadLevel(at: index, restoreSavedProgress: true)
        }

        isScreenTransitioning = true
        withAnimation(screenTransitionAnimation) {
            currentScreen = .game
        }
        persistCurrentScreen()
        scheduleLevelReveal(after: 0)

        transitionCleanupTask = Task { @MainActor in
            let nanoseconds = max(0, screenTransitionDuration + 0.02) * 1_000_000_000
            try? await Task.sleep(nanoseconds: UInt64(nanoseconds))
            guard !Task.isCancelled else { return }
            suspendLastPlayedWritesUntilTransitionEnd = false
            persistLastPlayedLevelIDForCurrentLevel()
            isScreenTransitioning = false
        }
    }

    private func exitLevel() {
        guard currentScreen == .game else { return }
        pendingLevelLoadTask?.cancel()
        levelRevealTask?.cancel()
        transitionCleanupTask?.cancel()
        clearActiveTileSelection()

        isScreenTransitioning = true
        withAnimation(screenTransitionAnimation) {
            currentScreen = .levels
        }
        transitionCleanupTask = Task { @MainActor in
            let nanoseconds = max(0, screenTransitionDuration + 0.02) * 1_000_000_000
            try? await Task.sleep(nanoseconds: UInt64(nanoseconds))
            guard !Task.isCancelled else { return }
            suspendLastPlayedWritesUntilTransitionEnd = false
            isScreenTransitioning = false
        }
        persistCurrentLevelProgressImmediately()
        persistCurrentScreen()
    }

    private func scheduleLevelReveal(after delay: Double) {
        levelRevealTask?.cancel()
        levelRevealTask = Task { @MainActor in
            let nanoseconds = max(0, delay) * 1_000_000_000
            try? await Task.sleep(nanoseconds: UInt64(nanoseconds))
            guard !Task.isCancelled, currentScreen == .game else { return }

            withAnimation(.easeIn(duration: levelRevealDuration)) {
                areLevelVisualsRevealed = true
            }
        }
    }

    private func levelExitSwipeGesture(in _: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard draggingLetterID == nil else { return }

                let horizontalTravel = value.translation.width
                let verticalTravel = abs(value.translation.height)
                let isMostlyHorizontal = abs(horizontalTravel) > (verticalTravel * 1.5)
                let isRightSwipe = horizontalTravel > 90

                guard isMostlyHorizontal, isRightSwipe else { return }
                exitLevel()
            }
    }

    private func leftEdgeExitSwipeGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(boardSpace))
            .onEnded { value in
                guard draggingLetterID == nil else { return }
                guard isPointWithinLeftEdgeSwipeRegion(
                    value.startLocation,
                    safeAreaInsets: geometry.safeAreaInsets
                ) else { return }

                let horizontalTravel = value.translation.width
                let verticalTravel = abs(value.translation.height)
                let isMostlyHorizontal = horizontalTravel > (verticalTravel * 1.35)
                let isRightSwipe = horizontalTravel > 48

                guard isMostlyHorizontal, isRightSwipe else { return }
                exitLevel()
            }
    }

    private func isPointWithinLeftEdgeSwipeRegion(_ point: CGPoint, safeAreaInsets: EdgeInsets) -> Bool {
        let leftEdgeSwipeWidth = leftEdgeSwipeCaptureWidth(safeAreaInsets: safeAreaInsets)
        return point.x <= leftEdgeSwipeWidth
    }

    private func leftEdgeSwipeCaptureWidth(safeAreaInsets: EdgeInsets) -> CGFloat {
        max(24, safeAreaInsets.leading + 12)
    }

    private func loadLevel(at index: Int, restoreSavedProgress: Bool) {
        shouldSuppressMilestonePopups = true
        currentLevelIndex = index
        let level = Self.activeLevels[index]
        logLevelOpen("board state creation", detail: "id=\(level.id)")
        game = GameState(
            sourceWords: level.startingWords,
            targetRowSizes: level.boardShape.targetRowLengths,
            goldTileExpectations: level.goldTileExpectations
        )
        clearActiveTileSelection()
        draggingLetterID = nil
        clearPreviewState()
        dragPosition = .zero
        activeDragStartTimestamp = nil
        pickupForceByLetterID = [:]
        slotFrames = [:]
        sourceFrames = [:]
        hasAchievedSplit = false
        hasAchievedPerfectSplit = false
        hintedRowIndices = []

        let restoredMoveHistory: [[PersistedTilePlacement]]?
        if restoreSavedProgress {
            restoredMoveHistory = restoreSavedProgressForCurrentLevel()
        } else {
            restoredMoveHistory = nil
        }
        initializeMoveHistoryForCurrentLevel(restoredMoveHistory: restoredMoveHistory)

        refreshValidRows()
        refreshBoardFrames()
        logLevelOpen("board layout creation", detail: "grid=\(currentBoardGrid.sourceRows)x\(currentBoardGrid.sourceColumns)/\(currentBoardGrid.targetRows)x\(currentBoardGrid.targetColumns)")
        shouldSuppressMilestonePopups = false
    }

    private var currentBoardGrid: BoardGridMetrics {
        Self.cachedBoardGrid
    }

    private func logLevelOpen(_ step: String, detail: String? = nil) {
        guard let start = levelOpenTraceStartTime else { return }
        let elapsedMS = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
        let levelPart = levelOpenTraceLevelID.map { " level=\($0)" } ?? ""
        let detailPart = detail.map { " \($0)" } ?? ""
        PerfLog.log("LevelOpen +\(elapsedMS)ms \(step)\(levelPart)\(detailPart)")
    }

    private func refreshBoardFrames() {
        let sourceFramesByLetter = computedSourceFrames(in: sourceGridFrame)
        if sourceFrames != sourceFramesByLetter {
            sourceFrames = sourceFramesByLetter
        }

        let slotFramesByID = computedTargetFrames(in: targetGridFrame)
        if slotFrames != slotFramesByID {
            slotFrames = slotFramesByID
        }
    }

    private func computedSourceFrames(in gridFrame: CGRect) -> [UUID: CGRect] {
        guard !gridFrame.isNull, gridFrame.width > 0, gridFrame.height > 0 else {
            return [:]
        }

        let sourceColumns = CGFloat(max(currentBoardGrid.sourceColumns, 1))
        let tileSize = (gridFrame.width - (BoardUI.sourceTileSpacing * (sourceColumns - 1))) / sourceColumns
        let rowStride = tileSize + BoardUI.sourceTileRowSpacing
        let columnStride = tileSize + BoardUI.sourceTileSpacing
        var frames: [UUID: CGRect] = [:]

        for rowIndex in game.sourceWords.indices {
            let letters = game.lettersForWord(rowIndex)
            for (columnIndex, letter) in letters.enumerated() {
                frames[letter.id] = CGRect(
                    x: gridFrame.minX + (CGFloat(columnIndex) * columnStride),
                    y: gridFrame.minY + (CGFloat(rowIndex) * rowStride),
                    width: tileSize,
                    height: tileSize
                )
            }
        }

        return frames
    }

    private func computedTargetFrames(in gridFrame: CGRect) -> [UUID: CGRect] {
        guard !gridFrame.isNull, gridFrame.width > 0, gridFrame.height > 0 else {
            return [:]
        }

        let targetColumns = CGFloat(max(currentBoardGrid.targetColumns, 1))
        let tileSize = (gridFrame.width - (BoardUI.targetTileHorizontalSpacing * (targetColumns - 1))) / targetColumns
        let rowStride = tileSize + BoardUI.targetRowSeparatorHeight
        let columnStride = tileSize + BoardUI.targetTileHorizontalSpacing
        var frames: [UUID: CGRect] = [:]

        for (rowIndex, rowSlots) in game.slotIDs.enumerated() {
            for (columnIndex, slotID) in rowSlots.enumerated() {
                frames[slotID] = CGRect(
                    x: gridFrame.minX + (CGFloat(columnIndex) * columnStride),
                    y: gridFrame.minY + (CGFloat(rowIndex) * rowStride),
                    width: tileSize,
                    height: tileSize
                )
            }
        }

        return frames
    }

    private func targetSlotView(slotID: UUID, rowIndex: Int, tileSize: CGFloat) -> some View {
        let cornerRadius = tileSize * BoardUI.targetTileCornerRatio
        let isGoldSlot = game.isGoldSlot(slotID)
        let shouldRevealGoldSlot = hasAchievedSplit && isGoldSlot
        let isCorrectGoldPlacement = shouldRevealGoldSlot && game.isCorrectlyPlacedGoldSlot(slotID)
        let isDropHoverSlot = previewTargetSlotID == slotID
        let placedLetter = game.letterInSlot(slotID)
        let isDraggingOriginSlot = placedLetter?.id == draggingLetterID
        let isSelectedTargetTile = selectedLetterID.map { placedLetter?.id == $0 } ?? false
        let isSelectedTargetSlot = selectedTargetSlotID == slotID
        let isHintLockedSlot = hintedRowIndices.contains(rowIndex)
        let rowWord = cachedCompletedRowWords.indices.contains(rowIndex)
            ? cachedCompletedRowWords[rowIndex]
            : game.wordForRow(rowIndex)
        let correctGoldFillStyle = AnyShapeStyle(
            RadialGradient(
                colors: [AppColor.criteriaGold.opacity(0.1), AppColor.criteriaGold],
                center: .center,
                startRadius: 1,
                endRadius: tileSize * 0.9
            )
        )
        let slotFillStyle: AnyShapeStyle = {
            guard areLevelVisualsRevealed else {
                return AnyShapeStyle(AppColor.tilePlaceholder)
            }

            if isCorrectGoldPlacement {
                return correctGoldFillStyle
            }
            if isDraggingOriginSlot {
                return AnyShapeStyle(shouldRevealGoldSlot ? AppColor.criteriaGold : AppColor.tilePlaceholder)
            }
            if shouldRevealGoldSlot {
                return AnyShapeStyle(AppColor.criteriaGold)
            }
            if rowWord != nil {
                return AnyShapeStyle(validRows.contains(rowIndex) ? AppColor.tileCorrect : AppColor.tileIncorrect)
            }
            if placedLetter != nil {
                return AnyShapeStyle(AppColor.tileFill)
            }
            return AnyShapeStyle(AppColor.tilePlaceholder)
        }()
        let slotShadowYOffset: CGFloat = {
            guard areLevelVisualsRevealed else { return 1 }
            if shouldRevealGoldSlot && (placedLetter == nil || isDraggingOriginSlot) { return 1 }
            if shouldRevealGoldSlot || rowWord != nil || placedLetter != nil {
                return -1
            }
            return 1
        }()
        let outerGlowColor = isCorrectGoldPlacement ? AppColor.criteriaGold.opacity(0.3) : .clear
        let outerGlowRadius: CGFloat = isCorrectGoldPlacement ? 4 : 0
        let correctGoldOutlineColor: Color = isCorrectGoldPlacement ? AppColor.criteriaGold.opacity(0.7) : .clear
        let correctGoldOutlineWidth: CGFloat = isCorrectGoldPlacement ? 1 : 0
        let selectionOverlayColor: Color = isDropHoverSlot ? Color.white.opacity(0) : .clear

        return ZStack {
            tileSurface(
                cornerRadius: cornerRadius,
                fillStyle: slotFillStyle,
                innerShadowColor: isCorrectGoldPlacement ? .white.opacity(1) : AppColor.tileInnerShadow,
                innerShadowRadius: isCorrectGoldPlacement ? 3 : 1,
                shadowYOffset: slotShadowYOffset
            )
                .frame(width: tileSize, height: tileSize)

            if let letter = placedLetter {
                letterTileView(
                    letter.character,
                    size: tileSize,
                    cornerRadius: cornerRadius,
                    fillStyle: slotFillStyle,
                    isGold: shouldRevealGoldSlot,
                    innerShadowColor: isCorrectGoldPlacement ? .white.opacity(0.5) : AppColor.tileInnerShadow,
                    innerShadowRadius: isCorrectGoldPlacement ? 3 : 1,
                    textOpacity: areLevelVisualsRevealed ? 1 : 0
                )
                    .opacity(isDraggingOriginSlot ? 0 : (isHintLockedSlot ? 0.5 : 1))
                    .allowsHitTesting(draggingLetterID == nil || draggingLetterID == letter.id)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(AppColor.selection, lineWidth: isSelectedTargetTile ? 3 : 0)
                    )
                    .background(
                        TileForceSensor { force in
                            updatePickupForce(force, for: letter.id)
                        }
                    )
                    .gesture(tileDragGesture(for: letter))
            }

        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(correctGoldOutlineColor, lineWidth: correctGoldOutlineWidth)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(selectionOverlayColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    AppColor.selection.opacity(
                        isDropHoverSlot
                            ? dropHoverOutlineOpacity
                            : (isSelectedTargetSlot ? 1 : 0)
                    ),
                    lineWidth: 3
                )
        )
        .contentShape(Rectangle())
        .shadow(color: outerGlowColor, radius: outerGlowRadius, x: 0, y: 0)
        .onTapGesture {
            handleTargetSlotTap(slotID: slotID)
        }
    }

    private func nearestFrameCandidate(
        in frames: [UUID: CGRect],
        to point: CGPoint,
        expansion: CGFloat
    ) -> (id: UUID, distanceSquared: CGFloat)? {
        frames
            .compactMap { id, frame -> (id: UUID, distanceSquared: CGFloat)? in
                let expandedFrame = frame.insetBy(dx: -expansion, dy: -expansion)
                guard expandedFrame.contains(point) else { return nil }

                let dx = frame.midX - point.x
                let dy = frame.midY - point.y
                return (id: id, distanceSquared: (dx * dx) + (dy * dy))
            }
            .min { $0.distanceSquared < $1.distanceSquared }
    }

    private func tileDragGesture(for letter: LetterTile) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(boardSpace))
            .onChanged { value in
                guard areLevelVisualsRevealed, !isHintLockedLetter(letter.id) else { return }
                let movementDistance = hypot(value.translation.width, value.translation.height)

                if draggingLetterID == nil {
                    let hasForcePickup = pickupForce(for: letter.id) >= pickupForceThreshold
                    let hasMovementPickup = movementDistance > pickupMovementThreshold
                    guard hasForcePickup || hasMovementPickup else { return }
                    triggerTilePickupHaptic()
                    dragOverlayScale = 0.88
                    draggingLetterID = letter.id
                    activeDragStartTimestamp = value.time.timeIntervalSinceReferenceDate
                    dragPosition = value.location
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.62)) {
                        dragOverlayScale = 1
                    }
                }

                if draggingLetterID == letter.id {
                    dragPosition = value.location
                    let hitTestPoint = dragHitTestPoint(for: value.location)
                    updateDropHoverDestination(at: hitTestPoint)
                }
            }
            .onEnded { value in
                guard areLevelVisualsRevealed, !isHintLockedLetter(letter.id) else { return }
                let movementDistance = hypot(value.translation.width, value.translation.height)
                if draggingLetterID == letter.id {
                    draggingLetterID = nil
                    dragOverlayScale = 1
                    clearPreviewState()

                    if movementDistance <= tapMovementThreshold {
                        handleTileTapGesture(letter: letter)
                        return
                    }

                    if shouldForceReturnToSource(for: value) {
                        if game.placements[letter.id] != nil {
                            returnLetterToSource(letterID: letter.id)
                            playTilePlacementSound()
                        }
                        activeDragStartTimestamp = nil
                        return
                    }

                    let hitTestPoint = dragHitTestPoint(for: value.location)
                    handleDrop(letterID: letter.id, at: hitTestPoint)
                    activeDragStartTimestamp = nil
                } else {
                    if movementDistance <= tapMovementThreshold {
                        handleTileTapGesture(letter: letter)
                    }
                }
                if draggingLetterID == nil {
                    activeDragStartTimestamp = nil
                }
                updatePickupForce(0, for: letter.id)
            }
    }

    private func triggerTilePickupHaptic() {
        guard isHapticsEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.3)
    }

    private func triggerTileHoverHaptic() {
        guard isHapticsEnabled else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    private func triggerTileDropHaptic() {
        guard isHapticsEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    private func dragHitTestPoint(for gestureLocation: CGPoint) -> CGPoint {
        // Hit testing follows finger position directly; visual ghost offset is render-only.
        gestureLocation
    }

    private func updatePickupForce(_ force: CGFloat, for letterID: UUID) {
        let clamped = min(max(force, 0), 1)
        if clamped > 0 {
            pickupForceByLetterID[letterID] = clamped
        } else {
            pickupForceByLetterID.removeValue(forKey: letterID)
        }
    }

    private func pickupForce(for letterID: UUID) -> CGFloat {
        pickupForceByLetterID[letterID] ?? 0
    }

    private func shouldForceReturnToSource(for value: DragGesture.Value) -> Bool {
        guard let dragStartTimestamp = activeDragStartTimestamp else { return false }

        let elapsed = max(0.016, value.time.timeIntervalSinceReferenceDate - dragStartTimestamp)
        let verticalSpeed = value.translation.height / elapsed
        let horizontalSpeed = abs(value.translation.width) / elapsed
        guard verticalSpeed > downwardReturnSpeedThreshold else { return false }
        guard verticalSpeed > (horizontalSpeed * 1.15) else { return false }

        let predictedVerticalSpeed = value.predictedEndTranslation.height / elapsed
        guard predictedVerticalSpeed >= (verticalSpeed * downwardReturnPredictedSpeedMultiplier) else { return false }
        return true
    }

    private func handleDrop(letterID: UUID, at point: CGPoint) {
        let dropStart = CFAbsoluteTimeGetCurrent()
        guard !isHintLockedLetter(letterID) else { return }
        let previousPlacements = currentTilePlacementsForPersistence()
        let previousPlacementsMS = Int(((CFAbsoluteTimeGetCurrent() - dropStart) * 1000).rounded())
        let originalSlotID = game.placements[letterID]
        clearPreviewState()

        let destination = currentDropDestination(at: point)
        let destinationMS = Int(((CFAbsoluteTimeGetCurrent() - dropStart) * 1000).rounded())

        if let destination {
            let hapticStart = CFAbsoluteTimeGetCurrent()
            triggerTileDropHaptic()
            let hapticMS = Int(((CFAbsoluteTimeGetCurrent() - hapticStart) * 1000).rounded())
            logDropDiagnostic("haptic=\(hapticMS)ms")
            let earlySoundStart = CFAbsoluteTimeGetCurrent()
            playTilePlacementSound()
            let earlySoundMS = Int(((CFAbsoluteTimeGetCurrent() - earlySoundStart) * 1000).rounded())
            logDropDiagnostic("early-sound=\(earlySoundMS)ms")
            if destination.isTarget {
                let slotID = destination.id
                if originalSlotID == slotID {
                    return
                }

                game.place(letterID: letterID, inSlot: slotID)
                let mutationMS = Int(((CFAbsoluteTimeGetCurrent() - dropStart) * 1000).rounded())
                let updatedPlacements = currentTilePlacementsForPersistence()
                let updatedPlacementsMS = Int(((CFAbsoluteTimeGetCurrent() - dropStart) * 1000).rounded())
                applyPlacementUpdate(
                    previousPlacements: previousPlacements,
                    updatedPlacements: updatedPlacements,
                    playSoundWhenUnchanged: false,
                    dropStart: dropStart,
                    playSoundOnChange: false
                )
                logDropDiagnostic(
                    "target-drop timings: pre=\(previousPlacementsMS)ms destination=\(destinationMS)ms mutation=\(mutationMS)ms post=\(updatedPlacementsMS)ms total=\(elapsedMS(since: dropStart))ms"
                )
                return
            }

            let sourceSlotID = destination.id
            let sourceSlotLetter = game.letterInSourceSlot(sourceSlotID)
            if sourceSlotLetter?.id == letterID {
                return
            }

            if originalSlotID != nil {
                game.returnToSourceWithoutSwap(letterID: letterID, preferredSourceSlotID: sourceSlotID)
            } else {
                game.returnToSource(letterID: letterID, preferredSourceSlotID: sourceSlotID)
            }
            let mutationMS = Int(((CFAbsoluteTimeGetCurrent() - dropStart) * 1000).rounded())
            let updatedPlacements = currentTilePlacementsForPersistence()
            let updatedPlacementsMS = Int(((CFAbsoluteTimeGetCurrent() - dropStart) * 1000).rounded())
            applyPlacementUpdate(
                previousPlacements: previousPlacements,
                updatedPlacements: updatedPlacements,
                playSoundWhenUnchanged: false,
                dropStart: dropStart,
                playSoundOnChange: false
            )
            logDropDiagnostic(
                "source-drop timings: pre=\(previousPlacementsMS)ms destination=\(destinationMS)ms mutation=\(mutationMS)ms post=\(updatedPlacementsMS)ms total=\(elapsedMS(since: dropStart))ms"
            )
            return
        }

        if isPointInSourceFallbackRegion(point) {
            triggerTileDropHaptic()
            let earlySoundStart = CFAbsoluteTimeGetCurrent()
            playTilePlacementSound()
            let earlySoundMS = Int(((CFAbsoluteTimeGetCurrent() - earlySoundStart) * 1000).rounded())
            logDropDiagnostic("early-sound=\(earlySoundMS)ms")
            if game.placements[letterID] != nil {
                game.returnToSource(letterID: letterID)
                let mutationMS = Int(((CFAbsoluteTimeGetCurrent() - dropStart) * 1000).rounded())
                let updatedPlacements = currentTilePlacementsForPersistence()
                let updatedPlacementsMS = Int(((CFAbsoluteTimeGetCurrent() - dropStart) * 1000).rounded())
                applyPlacementUpdate(
                    previousPlacements: previousPlacements,
                    updatedPlacements: updatedPlacements,
                    playSoundWhenUnchanged: false,
                    dropStart: dropStart,
                    playSoundOnChange: false
                )
                logDropDiagnostic(
                    "fallback-drop timings: pre=\(previousPlacementsMS)ms destination=\(destinationMS)ms mutation=\(mutationMS)ms post=\(updatedPlacementsMS)ms total=\(elapsedMS(since: dropStart))ms"
                )
            } else {
                // Sound already played at drop commit.
            }
            return
        }

        // Dropped outside any target/source hitbox: tile snaps back to its origin.
        playTilePlacementSound()
    }

    private func applyPlacementUpdate(
        previousPlacements: [PersistedTilePlacement],
        updatedPlacements: [PersistedTilePlacement],
        playSoundWhenUnchanged: Bool,
        dropStart: CFAbsoluteTime,
        playSoundOnChange: Bool
    ) {
        if previousPlacements != updatedPlacements {
            var soundMS = 0
            if playSoundOnChange {
                let soundStart = CFAbsoluteTimeGetCurrent()
                playTilePlacementSound()
                soundMS = Int(((CFAbsoluteTimeGetCurrent() - soundStart) * 1000).rounded())
            }
            let historyStart = CFAbsoluteTimeGetCurrent()
            recordMoveSnapshot(
                previousPlacements: previousPlacements,
                updatedPlacements: updatedPlacements
            )
            let historyMS = Int(((CFAbsoluteTimeGetCurrent() - historyStart) * 1000).rounded())
            let refreshStart = CFAbsoluteTimeGetCurrent()
            refreshValidRows()
            let refreshMS = Int(((CFAbsoluteTimeGetCurrent() - refreshStart) * 1000).rounded())
            logDropDiagnostic(
                "changed placement: sound=\(soundMS)ms history=\(historyMS)ms refresh=\(refreshMS)ms total=\(elapsedMS(since: dropStart))ms"
            )
        } else if playSoundWhenUnchanged {
            let soundStart = CFAbsoluteTimeGetCurrent()
            playTilePlacementSound()
            let soundMS = Int(((CFAbsoluteTimeGetCurrent() - soundStart) * 1000).rounded())
            logDropDiagnostic("unchanged placement: sound=\(soundMS)ms total=\(elapsedMS(since: dropStart))ms")
        }
    }

    private func elapsedMS(since start: CFAbsoluteTime) -> Int {
        Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
    }

    private func logDropDiagnostic(_ message: String) {
        guard isDropDiagnosticsEnabled else { return }
        PerfLog.log("DropDiag \(message)")
    }

    private func isPointInSourceFallbackRegion(_ point: CGPoint) -> Bool {
        if !targetGridFrame.isNull {
            return point.y >= (targetGridFrame.maxY - sourceDropHitboxExpansion)
        }

        if !sourceGridFrame.isNull {
            return point.y >= (sourceGridFrame.minY - sourceDropHitboxExpansion)
        }

        return false
    }

    private func currentDropDestination(at point: CGPoint) -> (isTarget: Bool, id: UUID)? {
        let targetCandidate = nearestFrameCandidate(
            in: slotFrames.filter { !isHintLockedSlot($0.key) },
            to: point,
            expansion: targetDropHitboxExpansion
        )
        let sourceCandidate = nearestFrameCandidate(
            in: sourceFrames,
            to: point,
            expansion: sourceDropHitboxExpansion
        )

        switch (targetCandidate, sourceCandidate) {
        case let (target?, source?):
            if target.distanceSquared <= source.distanceSquared {
                return (true, target.id)
            }
            return (false, source.id)
        case let (target?, nil):
            return (true, target.id)
        case let (nil, source?):
            return (false, source.id)
        case (nil, nil):
            return nil
        }
    }

    private func currentPreviewSourceLetter(at point: CGPoint) -> UUID? {
        nearestFrameCandidate(
            in: sourceFrames,
            to: point,
            expansion: sourceDropHitboxExpansion
        )?.id
    }

    private func updateDropHoverDestination(at point: CGPoint) {
        guard let draggingLetterID else {
            updateDelayedPreviewTargetSlot(nil)
            previewSourceLetterID = nil
            return
        }
        let isDraggingFromTargetArea = game.placements[draggingLetterID] != nil

        let destination = currentDropDestination(at: point)
        if let destination {
            if destination.isTarget {
                previewSourceLetterID = nil
                updateDelayedPreviewTargetSlot(destination.id)
                return
            }

            updateDelayedPreviewTargetSlot(nil)
            if isDraggingFromTargetArea {
                previewSourceLetterID = nil
            } else {
                previewSourceLetterID = destination.id
                clearActiveTileSelection()
            }
            return
        }

        // Fallback if no preferred destination resolved but source hitbox is nearby.
        let sourcePreview = currentPreviewSourceLetter(at: point)
        if let sourcePreview, !isDraggingFromTargetArea {
            updateDelayedPreviewTargetSlot(nil)
            previewSourceLetterID = sourcePreview
            clearActiveTileSelection()
        } else {
            updateDelayedPreviewTargetSlot(nil)
            previewSourceLetterID = nil
        }
    }

    private func handleBoardTapOutsideSwapArea(at point: CGPoint) {
        guard draggingLetterID == nil else { return }
        guard selectedLetterID != nil || selectedTargetSlotID != nil else { return }
        guard !isPointInSwapArea(point) else { return }
        clearActiveTileSelection()
    }

    private func isPointInSwapArea(_ point: CGPoint) -> Bool {
        currentDropDestination(at: point) != nil
    }

    private func updateDelayedPreviewTargetSlot(_ slotID: UUID?) {
        guard hoveredTargetSlotID != slotID else { return }
        if slotID != nil {
            triggerTileHoverHaptic()
        }
        hoveredTargetSlotID = slotID

        previewDelayTask?.cancel()
        previewDelayTask = nil
        guard draggingLetterID != nil else {
            previewTargetSlotID = nil
            return
        }
        previewTargetSlotID = slotID
        if slotID != nil {
            clearActiveTileSelection()
        }
    }

    private func scheduleDropHoverOutlineAnimation(for slotID: UUID?) {
        dropHoverOutlineTask?.cancel()
        dropHoverOutlineTask = nil
        dropHoverOutlineOpacity = slotID == nil ? 0 : 1
    }

    private func clearPreviewState() {
        previewDelayTask?.cancel()
        previewDelayTask = nil
        dropHoverOutlineTask?.cancel()
        dropHoverOutlineTask = nil
        dropHoverOutlineOpacity = 0
        hoveredTargetSlotID = nil
        previewTargetSlotID = nil
        previewSourceLetterID = nil
        dragOverlayScale = 1
        activeDragStartTimestamp = nil
    }

    private func handleTileTap(letter: LetterTile) {
        guard !isHintLockedLetter(letter.id) else { return }
        let now = CACurrentMediaTime()
        let placedSlotID = game.placements[letter.id]
        let isTargetDoubleTap = placedSlotID != nil
            && lastTargetTapSlotID == placedSlotID
            && (now - lastTargetTapTimestamp) <= targetDoubleTapMaxInterval
        let isSourceDoubleTap = !game.isPlaced(letter)
            && lastSourceTapLetterID == letter.id
            && (now - lastSourceTapTimestamp) <= targetDoubleTapMaxInterval

        if let placedSlotID {
            lastTargetTapSlotID = placedSlotID
            lastTargetTapTimestamp = now
        } else {
            lastSourceTapLetterID = letter.id
            lastSourceTapTimestamp = now
        }

        if isTargetDoubleTap,
           let placedSlotID,
           !isHintLockedSlot(placedSlotID) {
            returnLetterToSource(letterID: letter.id, preferredSourceSlotID: game.firstAvailableSourceSlotID())
            clearActiveTileSelection()
            playTilePlacementSound()
            return
        }

        if isSourceDoubleTap {
            placeSourceLetterIntoFirstOpenSlot(letter.id)
            return
        }

        if selectedLetterID == letter.id {
            clearActiveTileSelection()
            return
        }

        if let selectedSlotID = selectedTargetSlotID,
           !isHintLockedSlot(selectedSlotID) {
            let previousPlacements = currentTilePlacementsForPersistence()
            game.place(letterID: letter.id, inSlot: selectedSlotID)
            if previousPlacements != currentTilePlacementsForPersistence() {
                playTilePlacementSound()
                recordMoveSnapshotIfChanged(from: previousPlacements)
                refreshValidRows()
            }
            clearActiveTileSelection()
            return
        }

        if let selectedID = selectedLetterID,
           selectedID != letter.id,
           !isHintLockedLetter(selectedID),
           let selectedSlotID = game.placements[selectedID],
           game.placements[letter.id] == nil,
           !isHintLockedSlot(selectedSlotID) {
            let previousPlacements = currentTilePlacementsForPersistence()
            game.place(letterID: letter.id, inSlot: selectedSlotID)
            if previousPlacements != currentTilePlacementsForPersistence() {
                playTilePlacementSound()
                recordMoveSnapshotIfChanged(from: previousPlacements)
                refreshValidRows()
            }
            clearActiveTileSelection()
            return
        }

        if let selectedID = selectedLetterID,
                  !isHintLockedLetter(selectedID),
                  game.isPlaced(letter),
                  let slotID = game.placements[letter.id],
                  !isHintLockedSlot(slotID) {
            let previousPlacements = currentTilePlacementsForPersistence()
            game.place(letterID: selectedID, inSlot: slotID)
            if previousPlacements != currentTilePlacementsForPersistence() {
                playTilePlacementSound()
                recordMoveSnapshotIfChanged(from: previousPlacements)
                refreshValidRows()
            }
            clearActiveTileSelection()
        } else {
            selectLetter(letter.id)
        }
    }

    private func handleTileTapGesture(letter: LetterTile) {
        handleTileTap(letter: letter)
    }

    private func firstOpenTargetSlotID() -> UUID? {
        for rowSlots in game.slotIDs {
            for slotID in rowSlots {
                guard !isHintLockedSlot(slotID) else { continue }
                if game.letterInSlot(slotID) == nil {
                    return slotID
                }
            }
        }
        return nil
    }

    private func placeSourceLetterIntoFirstOpenSlot(_ letterID: UUID) {
        guard !isHintLockedLetter(letterID) else { return }
        guard game.placements[letterID] == nil else { return }
        guard let slotID = firstOpenTargetSlotID() else { return }

        let previousPlacements = currentTilePlacementsForPersistence()
        game.place(letterID: letterID, inSlot: slotID)
        if previousPlacements != currentTilePlacementsForPersistence() {
            playTilePlacementSound()
            recordMoveSnapshotIfChanged(from: previousPlacements)
            refreshValidRows()
        }
        clearActiveTileSelection()
    }

    private func handleTargetSlotTap(slotID: UUID) {
        guard !isHintLockedSlot(slotID) else { return }
        let now = CACurrentMediaTime()
        let isDoubleTap = lastTargetTapSlotID == slotID && (now - lastTargetTapTimestamp) <= targetDoubleTapMaxInterval
        lastTargetTapSlotID = slotID
        lastTargetTapTimestamp = now

        if isDoubleTap,
           let letter = game.letterInSlot(slotID),
           !isHintLockedLetter(letter.id) {
            returnLetterToSource(letterID: letter.id, preferredSourceSlotID: game.firstAvailableSourceSlotID())
            clearActiveTileSelection()
            playTilePlacementSound()
            return
        }

        if selectedTargetSlotID == slotID {
            clearActiveTileSelection()
            return
        }

        if let selectedID = selectedLetterID {
            guard !isHintLockedLetter(selectedID) else {
                clearActiveTileSelection()
                return
            }
            let previousPlacements = currentTilePlacementsForPersistence()
            game.place(letterID: selectedID, inSlot: slotID)
            if previousPlacements != currentTilePlacementsForPersistence() {
                playTilePlacementSound()
                recordMoveSnapshotIfChanged(from: previousPlacements)
                refreshValidRows()
            }
            clearActiveTileSelection()
        } else if let selectedSlotID = selectedTargetSlotID {
            if let letter = game.letterInSlot(slotID),
               !isHintLockedLetter(letter.id) {
                let previousPlacements = currentTilePlacementsForPersistence()
                game.place(letterID: letter.id, inSlot: selectedSlotID)
                if previousPlacements != currentTilePlacementsForPersistence() {
                    playTilePlacementSound()
                    recordMoveSnapshotIfChanged(from: previousPlacements)
                    refreshValidRows()
                }
                clearActiveTileSelection()
            } else {
                selectTargetSlot(slotID)
            }
        } else if let letter = game.letterInSlot(slotID) {
            selectLetter(letter.id)
        } else {
            selectTargetSlot(slotID)
        }
    }

    private func selectLetter(_ letterID: UUID) {
        selectedLetterID = letterID
        selectedTargetSlotID = nil
    }

    private func selectTargetSlot(_ slotID: UUID) {
        selectedTargetSlotID = slotID
        selectedLetterID = nil
    }

    private func clearActiveTileSelection() {
        selectedLetterID = nil
        selectedTargetSlotID = nil
    }

    private func toggleSound() {
        isSoundEnabled.toggle()
        UserDefaults.standard.set(isSoundEnabled, forKey: Self.soundEnabledStorageKey)
    }

    private func toggleHaptics() {
        isHapticsEnabled.toggle()
        UserDefaults.standard.set(isHapticsEnabled, forKey: Self.hapticsEnabledStorageKey)
    }

    private func setShuffleUsesAllLetters(_ enabled: Bool) {
        shuffleUsesAllLetters = enabled
        UserDefaults.standard.set(enabled, forKey: Self.shuffleAllLettersStorageKey)
    }

    private func setShuffleIncludesCorrectGoldTiles(_ enabled: Bool) {
        shuffleIncludesCorrectGoldTiles = enabled
        UserDefaults.standard.set(enabled, forKey: Self.shuffleGoldTilesStorageKey)
    }

    private func playTilePlacementSound() {
        guard isSoundEnabled else { return }
        SoundEffects.shared.play(.tilePlace)
    }

    private func playVictorySound() {
        guard isSoundEnabled else { return }
        SoundEffects.shared.play(.victory)
    }

    private func returnSelectedToSource(sourceSlotID: UUID? = nil) {
        guard let selectedID = selectedLetterID else { return }
        returnLetterToSource(letterID: selectedID, preferredSourceSlotID: sourceSlotID)
    }

    private func returnLetterToSource(letterID: UUID, preferredSourceSlotID: UUID? = nil) {
        guard !isHintLockedLetter(letterID) else { return }
        let previousPlacements = currentTilePlacementsForPersistence()

        game.returnToSource(letterID: letterID, preferredSourceSlotID: preferredSourceSlotID)
        recordMoveSnapshotIfChanged(from: previousPlacements)
        refreshValidRows()

        if selectedLetterID == letterID {
            clearActiveTileSelection()
        }
    }

    private func refreshValidRows() {
        let completedRowWords = game.slotIDs.indices.map(game.wordForRow)
        let criteriaRowWords = game.slotIDs.indices.map(game.criteriaWordForRow)
        let goldLetterMatches = game.goldLetterMatchesInOrder()

        cachedCompletedRowWords = completedRowWords
        cachedCriteriaRowWords = criteriaRowWords
        cachedGoldLetterMatches = goldLetterMatches

        validRows = Set(completedRowWords.enumerated().compactMap { rowIndex, word in
            guard let word else { return nil }
            return game.wordList.contains(word) ? rowIndex : nil
        })
        updateAchievedCriteria(rowWords: criteriaRowWords, goldLetterMatches: goldLetterMatches)
        scheduleDebouncedProgressSave()
    }

    private func updateAchievedCriteria(rowWords: [String?], goldLetterMatches: [Bool]) {
        let rows = criteriaRows(
            for: currentLevel,
            completedWords: validRows.count,
            totalWords: game.slotIDs.count,
            rowWords: rowWords,
            goldLetterMatches: goldLetterMatches
        )
        let isSplitCurrentlySatisfied = rows.first { $0.kind == .split }?.isSatisfied ?? false
        let isPerfectSplitCurrentlySatisfied = rows.first { $0.kind == .perfectSplit }?.isSatisfied ?? false
        let updatedHasAchievedSplit = hasAchievedSplit || isSplitCurrentlySatisfied
        let updatedHasAchievedPerfectSplit = hasAchievedPerfectSplit || isPerfectSplitCurrentlySatisfied
        let newlyReachedSplit = !hasAchievedSplit && updatedHasAchievedSplit
        let newlyReachedPerfectSplit = !hasAchievedPerfectSplit && updatedHasAchievedPerfectSplit

        if updatedHasAchievedSplit != hasAchievedSplit || updatedHasAchievedPerfectSplit != hasAchievedPerfectSplit {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hasAchievedSplit = updatedHasAchievedSplit
                hasAchievedPerfectSplit = updatedHasAchievedPerfectSplit
            }
        }

        if newlyReachedPerfectSplit {
            var updatedBadges = earnedBadgesByLevelID[currentLevel.id] ?? []
            let earned = badgesEarnedUponGoldAchievement(
                for: currentLevelIndex,
                usedHints: !hintedRowIndices.isEmpty
            )
            updatedBadges.formUnion(earned)
            earnedBadgesByLevelID[currentLevel.id] = updatedBadges
        }

        if currentScreen == .game, !shouldSuppressMilestonePopups {
            if newlyReachedPerfectSplit {
                activePopup = .perfectSplitVictory
            } else if newlyReachedSplit {
                activePopup = .splitVictory
            }
        }
    }

    private func resetSourceTilesToOriginalPositions() {
        game.recallAll()
        hintedRowIndices.removeAll()
        resetUndoHistoryToCurrentPlacements()
        refreshValidRows()
        clearActiveTileSelection()
        draggingLetterID = nil
        clearPreviewState()
    }

    private func shuffleLetters(useAllLetters: Bool) {
        let previousPlacements = currentTilePlacementsForPersistence()
        let protectedGoldSlotIDs = shuffleIncludesCorrectGoldTiles ? Set<UUID>() : correctlyPlacedGoldSlotIDs()

        let mutableRowIndices: Set<Int> = {
            if useAllLetters {
                return Set(game.slotIDs.indices.filter { !hintedRowIndices.contains($0) })
            }

            return Set(game.slotIDs.indices.filter { rowIndex in
                !hintedRowIndices.contains(rowIndex) && !validRows.contains(rowIndex)
            })
        }()

        let targetSlotIDs = mutableRowIndices
            .sorted()
            .flatMap { rowIndex in
                game.slotIDs[rowIndex].filter {
                    !isHintLockedSlot($0) &&
                    !protectedGoldSlotIDs.contains($0)
                }
            }

        let letterIDsToShuffle = game.letters
            .filter { letter in
                guard !isHintLockedLetter(letter.id) else { return false }
                if let slotID = game.placements[letter.id],
                   protectedGoldSlotIDs.contains(slotID) {
                    return false
                }

                if useAllLetters {
                    return true
                }

                guard let slotID = game.placements[letter.id] else { return true }
                guard let slotPosition = game.slotPosition(for: slotID) else { return true }
                return mutableRowIndices.contains(slotPosition.rowIndex)
            }
            .map(\.id)

        guard !letterIDsToShuffle.isEmpty else { return }

        for letterID in letterIDsToShuffle {
            game.returnToSource(letterID: letterID)
        }

        let shuffledLetterIDs = letterIDsToShuffle.shuffled()
        let shuffledSlotIDs = targetSlotIDs.shuffled()

        for (letterID, slotID) in zip(shuffledLetterIDs, shuffledSlotIDs) {
            game.place(letterID: letterID, inSlot: slotID)
        }

        if previousPlacements != currentTilePlacementsForPersistence() {
            recordMoveSnapshotIfChanged(from: previousPlacements)
            refreshValidRows()
        }

        clearActiveTileSelection()
        draggingLetterID = nil
        clearPreviewState()
    }

    private func correctlyPlacedGoldSlotIDs() -> Set<UUID> {
        Set(game.goldSlotExpectations.compactMap { expectation in
            guard let placedCharacter = game.letterInSlot(expectation.slotID)?.character.first else {
                return nil
            }

            let normalizedCharacter = Character(String(placedCharacter).uppercased())
            return normalizedCharacter == expectation.letter ? expectation.slotID : nil
        })
    }

    private func useHint() {
        let hintRowIndex = hintedRowIndices.count
        guard currentLevel.answerRows.indices.contains(hintRowIndex),
              game.slotIDs.indices.contains(hintRowIndex) else {
            return
        }

        let targetRowSlots = game.slotIDs[hintRowIndex]
        let answerCharacters = Array(currentLevel.answerRows[hintRowIndex].uppercased())
        guard answerCharacters.count == targetRowSlots.count else { return }

        var plannedAssignments: [(letterID: UUID, slotID: UUID)] = []
        var usedLetterIDs: Set<UUID> = []

        for (columnIndex, slotID) in targetRowSlots.enumerated() {
            let answerCharacter = answerCharacters[columnIndex]
            if let currentLetter = game.letterInSlot(slotID),
               !isHintLockedLetter(currentLetter.id),
               Character(currentLetter.character.uppercased()) == answerCharacter {
                plannedAssignments.append((letterID: currentLetter.id, slotID: slotID))
                usedLetterIDs.insert(currentLetter.id)
            }
        }

        for (columnIndex, slotID) in targetRowSlots.enumerated() {
            guard !plannedAssignments.contains(where: { $0.slotID == slotID }) else { continue }
            let answerCharacter = answerCharacters[columnIndex]

            let candidateLetter = game.letters
                .filter { letter in
                    Character(letter.character.uppercased()) == answerCharacter &&
                    !usedLetterIDs.contains(letter.id) &&
                    !isHintLockedLetter(letter.id)
                }
                .sorted { lhs, rhs in
                    let lhsIsPlaced = game.placements[lhs.id] != nil
                    let rhsIsPlaced = game.placements[rhs.id] != nil
                    if lhsIsPlaced != rhsIsPlaced { return !lhsIsPlaced }
                    if lhs.sourceWordIndex != rhs.sourceWordIndex { return lhs.sourceWordIndex < rhs.sourceWordIndex }
                    return lhs.positionInWord < rhs.positionInWord
                }
                .first

            guard let candidateLetter else { return }
            plannedAssignments.append((letterID: candidateLetter.id, slotID: slotID))
            usedLetterIDs.insert(candidateLetter.id)
        }

        for assignment in plannedAssignments {
            if let displacedLetter = game.letterInSlot(assignment.slotID),
               displacedLetter.id != assignment.letterID,
               !isHintLockedLetter(displacedLetter.id) {
                game.returnToSource(letterID: displacedLetter.id)
            }

            if let currentSlotID = game.placements[assignment.letterID],
               currentSlotID != assignment.slotID {
                game.returnToSource(letterID: assignment.letterID)
            }

            game.place(letterID: assignment.letterID, inSlot: assignment.slotID)
        }

        let isRowFullyHinted = targetRowSlots.enumerated().allSatisfy { columnIndex, slotID in
            guard let placedCharacter = game.letterInSlot(slotID)?.character.first else {
                return false
            }
            return Character(String(placedCharacter).uppercased()) == answerCharacters[columnIndex]
        }
        guard isRowFullyHinted else { return }

        hintedRowIndices.insert(hintRowIndex)
        resetUndoHistoryToCurrentPlacements()
        refreshValidRows()
        clearActiveTileSelection()
        draggingLetterID = nil
        clearPreviewState()
    }

    private func badgesEarnedUponGoldAchievement(for levelIndex: Int, usedHints: Bool) -> Set<LevelAchievementBadge> {
        var badges: Set<LevelAchievementBadge> = []
        if !usedHints {
            badges.insert(.holySplit)
        }

        if let releaseDate = levelDate(for: levelIndex),
           let endWindow = Self.levelDateCalendar.date(byAdding: .day, value: 1, to: releaseDate) {
            let achievementDate = GameDateProvider.currentDate()
            if achievementDate >= releaseDate && achievementDate < endWindow {
                badges.insert(.licketySplit)
            }
        }

        return badges
    }

    private func placeGoldTilesInCorrectOrder() {
        let expectations = game.goldSlotExpectations
        guard !expectations.isEmpty else { return }

        let previousPlacements = currentTilePlacementsForPersistence()
        var plannedAssignments: [(letterID: UUID, slotID: UUID)] = []
        var usedLetterIDs: Set<UUID> = []

        for expectation in expectations {
            guard let currentLetter = game.letterInSlot(expectation.slotID),
                  Character(currentLetter.character.uppercased()) == expectation.letter else {
                continue
            }

            plannedAssignments.append((letterID: currentLetter.id, slotID: expectation.slotID))
            usedLetterIDs.insert(currentLetter.id)
        }

        for expectation in expectations {
            guard !plannedAssignments.contains(where: { $0.slotID == expectation.slotID }) else { continue }

            if let occupiedLetter = game.letterInSlot(expectation.slotID),
               isHintLockedLetter(occupiedLetter.id) {
                return
            }

            let candidateLetter = game.letters
                .filter { letter in
                    Character(letter.character.uppercased()) == expectation.letter &&
                    !usedLetterIDs.contains(letter.id) &&
                    !isHintLockedLetter(letter.id)
                }
                .sorted { lhs, rhs in
                    let lhsIsPlaced = game.placements[lhs.id] != nil
                    let rhsIsPlaced = game.placements[rhs.id] != nil
                    if lhsIsPlaced != rhsIsPlaced { return !lhsIsPlaced }
                    if lhs.sourceWordIndex != rhs.sourceWordIndex { return lhs.sourceWordIndex < rhs.sourceWordIndex }
                    return lhs.positionInWord < rhs.positionInWord
                }
                .first

            guard let candidateLetter else { return }
            plannedAssignments.append((letterID: candidateLetter.id, slotID: expectation.slotID))
            usedLetterIDs.insert(candidateLetter.id)
        }

        for assignment in plannedAssignments {
            if let displacedLetter = game.letterInSlot(assignment.slotID),
               displacedLetter.id != assignment.letterID {
                guard !isHintLockedLetter(displacedLetter.id) else { return }
                game.returnToSource(letterID: displacedLetter.id)
            }

            if let currentSlotID = game.placements[assignment.letterID],
               currentSlotID != assignment.slotID {
                game.returnToSource(letterID: assignment.letterID)
            }

            game.place(letterID: assignment.letterID, inSlot: assignment.slotID)
        }

        if previousPlacements != currentTilePlacementsForPersistence() {
            playTilePlacementSound()
            recordMoveSnapshotIfChanged(from: previousPlacements)
            refreshValidRows()
        }

        clearActiveTileSelection()
        draggingLetterID = nil
        clearPreviewState()
    }

    private func isHintLockedSlot(_ slotID: UUID) -> Bool {
        guard let slotPosition = game.slotPosition(for: slotID) else { return false }
        return hintedRowIndices.contains(slotPosition.rowIndex)
    }

    private func isHintLockedLetter(_ letterID: UUID) -> Bool {
        guard let slotID = game.placements[letterID] else { return false }
        return isHintLockedSlot(slotID)
    }

    private func restorePersistedProgressOnLaunch() {
        let fallbackLevelIndex = 0
        let restoredLevelIndex = progressSnapshot.lastPlayedLevelID.flatMap { levelID in
            Self.activeLevels.firstIndex { $0.id == levelID }
        } ?? fallbackLevelIndex
        let restoredScreen = progressSnapshot.lastScreen ?? .levels

        loadLevel(at: restoredLevelIndex, restoreSavedProgress: true)
        switch restoredScreen {
        case .levels:
            currentScreen = .levels
            areLevelVisualsRevealed = false
        case .game:
            currentScreen = .game
            areLevelVisualsRevealed = true
        }
    }

    private func restoreSavedProgressForCurrentLevel() -> [[PersistedTilePlacement]]? {
        guard let persistedLevel = progressSnapshot.levelsByID[currentLevel.id] else { return nil }

        hasAchievedSplit = persistedLevel.hasAchievedSplit
        hasAchievedPerfectSplit = persistedLevel.hasAchievedPerfectSplit
        hintedRowIndices = Set(
            persistedLevel.hintedRowIndices.filter { game.slotIDs.indices.contains($0) }
        )
        earnedBadgesByLevelID[currentLevel.id] = Set(
            persistedLevel.earnedGoldBadges.compactMap(LevelAchievementBadge.init(rawValue:))
        )

        for placement in persistedLevel.tilePlacements {
            guard let letterID = game.letterID(
                sourceWordIndex: placement.sourceWordIndex,
                positionInWord: placement.positionInWord
            ),
            let slotID = game.slotID(rowIndex: placement.rowIndex, columnIndex: placement.columnIndex) else {
                continue
            }

            game.place(letterID: letterID, inSlot: slotID)
        }

        return persistedLevel.moveHistory
    }

    private func currentTilePlacementsForPersistence() -> [PersistedTilePlacement] {
        game.placements
            .compactMap { letterID, slotID in
                guard let letter = game.letter(byID: letterID),
                      let slotPosition = game.slotPosition(for: slotID) else {
                    return nil
                }

                return PersistedTilePlacement(
                    sourceWordIndex: letter.sourceWordIndex,
                    positionInWord: letter.positionInWord,
                    rowIndex: slotPosition.rowIndex,
                    columnIndex: slotPosition.columnIndex
                )
            }
            .sorted {
                if $0.rowIndex != $1.rowIndex { return $0.rowIndex < $1.rowIndex }
                if $0.columnIndex != $1.columnIndex { return $0.columnIndex < $1.columnIndex }
                if $0.sourceWordIndex != $1.sourceWordIndex { return $0.sourceWordIndex < $1.sourceWordIndex }
                return $0.positionInWord < $1.positionInWord
            }
    }

    private func initializeMoveHistoryForCurrentLevel(restoredMoveHistory: [[PersistedTilePlacement]]?) {
        let currentPlacements = currentTilePlacementsForPersistence()
        var history = restoredMoveHistory ?? moveHistoryByLevelID[currentLevel.id] ?? []

        if history.isEmpty || history.last != currentPlacements {
            history.append(currentPlacements)
        }

        let maxSnapshots = Self.maxUndoMovesPerLevel + 1
        if history.count > maxSnapshots {
            history.removeFirst(history.count - maxSnapshots)
        }

        moveHistoryByLevelID[currentLevel.id] = history
    }

    private func recordMoveSnapshotIfChanged(from previousPlacements: [PersistedTilePlacement]) {
        let currentPlacements = currentTilePlacementsForPersistence()
        guard currentPlacements != previousPlacements else { return }

        var history = moveHistoryByLevelID[currentLevel.id] ?? [previousPlacements]
        if history.last != currentPlacements {
            history.append(currentPlacements)
        }

        let maxSnapshots = Self.maxUndoMovesPerLevel + 1
        if history.count > maxSnapshots {
            history.removeFirst(history.count - maxSnapshots)
        }

        moveHistoryByLevelID[currentLevel.id] = history
    }

    private func recordMoveSnapshot(
        previousPlacements: [PersistedTilePlacement],
        updatedPlacements: [PersistedTilePlacement]
    ) {
        var history = moveHistoryByLevelID[currentLevel.id] ?? [previousPlacements]
        if history.last != updatedPlacements {
            history.append(updatedPlacements)
        }

        let maxSnapshots = Self.maxUndoMovesPerLevel + 1
        if history.count > maxSnapshots {
            history.removeFirst(history.count - maxSnapshots)
        }

        moveHistoryByLevelID[currentLevel.id] = history
    }

    private func resetUndoHistoryToCurrentPlacements() {
        moveHistoryByLevelID[currentLevel.id] = [currentTilePlacementsForPersistence()]
    }

    private func applyPersistedTilePlacements(_ tilePlacements: [PersistedTilePlacement]) {
        game.recallAll()

        for placement in tilePlacements {
            guard let letterID = game.letterID(
                sourceWordIndex: placement.sourceWordIndex,
                positionInWord: placement.positionInWord
            ),
            let slotID = game.slotID(rowIndex: placement.rowIndex, columnIndex: placement.columnIndex) else {
                continue
            }

            game.place(letterID: letterID, inSlot: slotID)
        }
    }

    private func undoLastMove() {
        var history = moveHistoryByLevelID[currentLevel.id] ?? [currentTilePlacementsForPersistence()]
        let currentPlacements = currentTilePlacementsForPersistence()
        if history.last != currentPlacements {
            history.append(currentPlacements)
        }

        guard history.count > 1 else { return }

        history.removeLast()
        let previousPlacements = history.last ?? []
        applyPersistedTilePlacements(previousPlacements)
        moveHistoryByLevelID[currentLevel.id] = history

        refreshValidRows()
        clearActiveTileSelection()
        draggingLetterID = nil
        clearPreviewState()
        refreshBoardFrames()
    }

    private func scheduleDebouncedProgressSave(delay: TimeInterval = 0.25) {
        debouncedProgressSaveTask?.cancel()
        debouncedProgressSaveTask = Task { @MainActor in
            let nanoseconds = max(0, delay) * 1_000_000_000
            try? await Task.sleep(nanoseconds: UInt64(nanoseconds))
            guard !Task.isCancelled else { return }
            persistCurrentLevelProgressImmediately()
        }
    }

    private func persistCurrentLevelProgressImmediately() {
        debouncedProgressSaveTask?.cancel()
        debouncedProgressSaveTask = nil
        guard Self.activeLevels.indices.contains(currentLevelIndex) else { return }
        let levelID = currentLevel.id
        let persistedLevel = PersistedLevelProgress(
            tilePlacements: currentTilePlacementsForPersistence(),
            hasAchievedSplit: hasAchievedSplit,
            hasAchievedPerfectSplit: hasAchievedPerfectSplit,
            moveHistory: moveHistoryByLevelID[levelID],
            hintedRowIndices: hintedRowIndices.sorted(),
            earnedGoldBadges: (earnedBadgesByLevelID[levelID] ?? [])
                .map(\.rawValue)
                .sorted()
        )

        if !suspendLastPlayedWritesUntilTransitionEnd {
            progressSnapshot.lastPlayedLevelID = levelID
        }
        progressSnapshot.levelsByID[levelID] = persistedLevel
        LocalProgressStorage.save(progressSnapshot)
    }

    private func persistLastPlayedLevelIDForCurrentLevel() {
        guard Self.activeLevels.indices.contains(currentLevelIndex) else { return }
        let levelID = currentLevel.id
        progressSnapshot.lastPlayedLevelID = levelID
        LocalProgressStorage.save(progressSnapshot)
    }

    private func persistCurrentScreen() {
        let persistedScreen: PersistedGameProgress.PersistedScreen
        switch currentScreen {
        case .levels:
            persistedScreen = .levels
        case .loading, .game:
            persistedScreen = .game
        }

        progressSnapshot.lastScreen = persistedScreen
        LocalProgressStorage.save(progressSnapshot)
    }

    private func presentGameInfoPopupIfNeeded() {
        let hasShownPopup = UserDefaults.standard.bool(forKey: Self.hasShownInfoPopupStorageKey)
        guard !hasShownPopup else { return }
        UserDefaults.standard.set(true, forKey: Self.hasShownInfoPopupStorageKey)
        activePopup = .gameInfo
    }

    private func shareAchievement(badgeName: String) {
        let levelLabel = levelDisplayLabel(for: currentLevelIndex)
        pendingShareMessage = "I just got a \(badgeName) on SplitHappens for \(levelLabel). Think you can match it?"
        activePopup = nil
    }

    private func resetAllLevelProgress() {
        progressSnapshot.levelsByID = [:]
        LocalProgressStorage.save(progressSnapshot)

        moveHistoryByLevelID.removeAll()
        earnedBadgesByLevelID.removeAll()
        hasAchievedSplit = false
        hasAchievedPerfectSplit = false
        hintedRowIndices.removeAll()
        resetSourceTilesToOriginalPositions()
    }

    private func handlePopupDismiss() {
        guard let pendingShareMessage else { return }
        self.pendingShareMessage = nil
        sharePayload = SharePayload(message: pendingShareMessage)
    }

    private var completedStatsSummary: (played: Int, split: Int, perfectSplit: Int, noBadge: Int) {
        var splitOnlyCount = 0
        var perfectSplitCount = 0
        let totalLevels = Self.activeLevels.count

        for level in Self.activeLevels {
            guard let levelProgress = progressSnapshot.levelsByID[level.id] else { continue }
            if levelProgress.hasAchievedPerfectSplit {
                perfectSplitCount += 1
            } else if levelProgress.hasAchievedSplit {
                splitOnlyCount += 1
            }
        }

        let noBadgeCount = max(totalLevels - (perfectSplitCount + splitOnlyCount), 0)

        return (
            played: progressSnapshot.levelsByID.count,
            split: splitOnlyCount,
            perfectSplit: perfectSplitCount,
            noBadge: noBadgeCount
        )
    }

    @ViewBuilder
    private func popupSheetContent(for popup: ActivePopup) -> some View {
        switch popup {
        case .settings:
            SettingsPopupView(
                isSoundEnabled: isSoundEnabled,
                isHapticsEnabled: isHapticsEnabled,
                onHowToPlay: {
                    activePopup = .gameInfo
                },
                onViewStats: {
                    activePopup = .stats
                },
                onAbout: {
                    activePopup = .about
                },
                onFeedbackEmail: {
                    openSupportEmail()
                },
                onToggleSound: {
                    toggleSound()
                },
                onToggleHaptics: {
                    toggleHaptics()
                },
                onClose: {
                    activePopup = nil
                }
            )
        case .gameInfo:
            IntroPopupView {
                activePopup = nil
            }
        case .levelNote:
            if let note = currentLevelNote {
                LevelNotePopupView(note: note)
            } else {
                EmptyView()
            }
        case .stats:
            let stats = completedStatsSummary

            StatsPopupView(
                played: stats.played,
                split: stats.split,
                perfectSplit: stats.perfectSplit,
                noBadge: stats.noBadge,
                onResetProgress: {
                    resetAllLevelProgress()
                }
            ) {
                activePopup = nil
            }
        case .splitVictory, .perfectSplitVictory:
            let victorySpacingAfterTitle: CGFloat = 20
            let victorySpacingAfterSubtitle: CGFloat = 20
            let levelText = levelSubtitle(for: currentLevelIndex) ?? levelDisplayLabel(for: currentLevelIndex)
            let earnedGoldBadges = (earnedBadgesByLevelID[currentLevel.id] ?? [])
                .sorted { lhs, rhs in
                    (LevelAchievementBadge.allCases.firstIndex(of: lhs) ?? 0) <
                    (LevelAchievementBadge.allCases.firstIndex(of: rhs) ?? 0)
                }
            let hasTwoGoldBadges = earnedGoldBadges.count == 2
            let badgeName: String = {
                switch popup {
                case .splitVictory:
                    return "Split"
                case .perfectSplitVictory:
                    return "Perfect Split"
                default:
                    return "Split"
                }
            }()
            let secondaryButtonTitle = popup == .perfectSplitVictory ? "Level Select" : "Go for Perfect"
            let secondaryButtonIcon = popup == .perfectSplitVictory ? "square.grid.2x2.fill" : "trophy.fill"
            let badgeAccentColor: Color = {
                switch popup {
                case .splitVictory:
                    return AppColor.split
                case .perfectSplitVictory:
                    return AppColor.darkGold
                default:
                    return AppColor.textDefault
                }
            }()
            let victoryTitle: String = {
                switch popup {
                case .splitVictory:
                    return "You Split It!"
                case .perfectSplitVictory:
                    return "Perfect Split!"
                default:
                    return "You Split It!"
                }
            }()

            PopupSheetScaffold(
                iconSystemName: "trophy.fill",
                iconAssetName: "BananaBlack",
                iconAssetTint: badgeAccentColor,
                title: victoryTitle,
                bodyLines: ["You just got a \(badgeName) for \(levelText)."],
                bodyLineFontWeight: .semibold,
                spacingAfterTitle: victorySpacingAfterTitle,
                spacingAfterBodyLines: victorySpacingAfterSubtitle,
                pinActionAreaToBottom: true,
                actionAreaBottomPadding: 0,
                onClose: {
                    activePopup = nil
                }
            ) {
                VStack(spacing: 20) {
                    if popup == .perfectSplitVictory, !earnedGoldBadges.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(earnedGoldBadges, id: \.rawValue) { badge in
                                VStack(spacing: 2) {
                                    Image(systemName: badge.systemImage)
                                        .font(.system(size: 50, weight: .bold))
                                        .foregroundStyle(AppColor.buttonActive)
                                    Text(badge.title)
                                        .font(.system(size: 24, weight: .bold))
                                        .foregroundStyle(AppColor.textDefault)

                                    Text(badgeSubtitle(for: badge))
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(AppColor.textDefault.opacity(0.9))
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 2)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 8)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: hasTwoGoldBadges ? 190 : nil,
                                    maxHeight: hasTwoGoldBadges ? 190 : nil,
                                    alignment: .top
                                )
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(AppColor.tilePlaceholder)
                                )
                                
                            }
                        }
                        .padding(.horizontal, 0)
                    }
                    Spacer()
                        .frame(height: 20)

                    HStack(spacing: 14) {
                        modalIconButton(title: "Share", systemImage: "square.and.arrow.up") {
                            shareAchievement(badgeName: badgeName)
                        }
                        modalIconButton(title: secondaryButtonTitle, systemImage: secondaryButtonIcon) {
                            if popup == .perfectSplitVictory {
                                activePopup = nil
                                exitLevel()
                            } else {
                                activePopup = nil
                            }
                        }
                    }
                    .padding(.top, 80)
                    .padding(.bottom, 0)
                }
            }
        case .about:
            PopupSheetScaffold(
                title: "About",
                bodyLines: ["Copyright 2026. All rights reserved."],
                showsActionArea: false,
                onClose: {
                    activePopup = nil
                }
            ) {
                EmptyView()
            }
        }
    }

    private func openSupportEmail() {
        guard let emailURL = URL(string: "mailto:uncommoncrawl@gmail.com") else { return }
        UIApplication.shared.open(emailURL)
    }

    private func badgeSubtitle(for badge: LevelAchievementBadge) -> String {
        switch badge {
        case .holySplit:
            return "Achieve a Perfect Split with zero hints"
        case .licketySplit:
            return "Achieve a Perfect Split on day of release"
        }
    }

    private func modalIconButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 45, weight: .semibold))
                    .foregroundStyle(AppColor.textDefault)
                    .frame(height: 54, alignment: .center)
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(AppColor.textDefault)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 124, alignment: .top)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func letterTileView(
        _ character: String,
        size: CGFloat,
        cornerRadius: CGFloat,
        fillColor: Color? = nil,
        fillStyle: AnyShapeStyle? = nil,
        isGold: Bool = false,
        innerShadowColor: Color = AppColor.tileInnerShadow,
        innerShadowRadius: CGFloat = 1,
        textOpacity: Double = 1
    ) -> some View {
        Text(character)
            .font(.system(size: max(16, size * 0.6), weight: .bold))
            .foregroundStyle(AppColor.textDefault)
            .opacity(textOpacity)
            .frame(width: size, height: size)
            .background(
                tileSurface(
                    cornerRadius: cornerRadius,
                    fillStyle: fillStyle ?? AnyShapeStyle(fillColor ?? (isGold ? AppColor.criteriaGold : AppColor.tileFill)),
                    innerShadowColor: innerShadowColor,
                    innerShadowRadius: innerShadowRadius
                )
            )
    }

    private func tileSurface(cornerRadius: CGFloat, fill: Color, shadowYOffset: CGFloat = -1) -> some View {
        tileSurface(
            cornerRadius: cornerRadius,
            fillStyle: AnyShapeStyle(fill),
            innerShadowColor: AppColor.tileInnerShadow,
            innerShadowRadius: 1,
            shadowYOffset: shadowYOffset
        )
    }

    private func tileSurface(
        cornerRadius: CGFloat,
        fillStyle: AnyShapeStyle,
        innerShadowColor: Color,
        innerShadowRadius: CGFloat,
        shadowYOffset: CGFloat = -1
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(
                fillStyle.shadow(
                    .inner(
                        color: innerShadowColor,
                        radius: innerShadowRadius,
                        x: 0,
                        y: shadowYOffset
                    )
                )
            )
    }

    private func emptyGridCell(size: CGFloat) -> some View {
        Color.clear
            .frame(width: size, height: size)
    }
}

private struct TileForceSensor: UIViewRepresentable {
    let onForceChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onForceChanged: onForceChanged)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let recognizer = ForceTouchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleForceChange(_:))
        )
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onForceChanged = onForceChanged
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            coordinator.onForceChanged(0)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onForceChanged: (CGFloat) -> Void

        init(onForceChanged: @escaping (CGFloat) -> Void) {
            self.onForceChanged = onForceChanged
        }

        @objc
        func handleForceChange(_ recognizer: ForceTouchGestureRecognizer) {
            onForceChanged(recognizer.normalizedForce)
            if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                onForceChanged(0)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private final class ForceTouchGestureRecognizer: UIGestureRecognizer {
    private(set) var normalizedForce: CGFloat = 0
    private var touchStartTimestamp: TimeInterval?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else {
            state = .failed
            return
        }
        touchStartTimestamp = touch.timestamp
        normalizedForce = forceFraction(for: touch)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else {
            state = .failed
            return
        }
        normalizedForce = forceFraction(for: touch)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        normalizedForce = 0
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        normalizedForce = 0
        state = .cancelled
    }

    override func reset() {
        normalizedForce = 0
        touchStartTimestamp = nil
    }

    private func forceFraction(for touch: UITouch) -> CGFloat {
        if touch.maximumPossibleForce > 1 {
            return min(max(touch.force / touch.maximumPossibleForce, 0), 1)
        }

        // Fallback for devices/simulators that do not report pressure.
        let elapsed = max(0, touch.timestamp - (touchStartTimestamp ?? touch.timestamp))
        return min(1, CGFloat(elapsed / 0.14))
    }
}

private final class SoundEffects {
    enum Effect: String {
        case tilePlace = "TilePlace"
        case victory = "Victory"

        var fileExtension: String {
            switch self {
            case .tilePlace:
                return "wav"
            case .victory:
                return "mp3"
            }
        }
    }

    static let shared = SoundEffects()

    private var players: [Effect: AVAudioPlayer] = [:]
    private var tilePlaceSoundID: SystemSoundID = 0

    private init() {
        configureAudioSession()
        prepareTilePlaceSound()
        prepareVictorySound()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("Failed to configure audio session for mixing: \(error)")
            #endif
        }
    }

    func play(_ effect: Effect) {
        if effect == .tilePlace {
            AudioServicesPlaySystemSound(tilePlaceSoundID)
            return
        }

        if let player = players[effect] {
            player.currentTime = 0
            player.play()
            return
        }

        guard let url = ResourceBundle.url(forResource: effect.rawValue, withExtension: effect.fileExtension) else {
            return
        }

        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            return
        }

        player.prepareToPlay()
        players[effect] = player
        player.play()
    }

    private func prepareTilePlaceSound() {
        guard tilePlaceSoundID == 0 else { return }
        guard let url = ResourceBundle.url(forResource: Effect.tilePlace.rawValue, withExtension: Effect.tilePlace.fileExtension) else {
            return
        }

        AudioServicesCreateSystemSoundID(url as CFURL, &tilePlaceSoundID)
    }

    private func prepareVictorySound() {
        guard players[.victory] == nil else { return }
        guard let url = ResourceBundle.url(forResource: Effect.victory.rawValue, withExtension: Effect.victory.fileExtension) else {
            return
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            return
        }

        player.prepareToPlay()
        players[.victory] = player
    }
}

private struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeDetectingViewController {
        let viewController = ShakeDetectingViewController()
        viewController.onShake = onShake
        return viewController
    }

    func updateUIViewController(_ uiViewController: ShakeDetectingViewController, context: Context) {
        uiViewController.onShake = onShake
    }
}

private final class ShakeDetectingViewController: UIViewController {
    var onShake: (() -> Void)?

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resignFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        onShake?()
    }
}

#Preview {
    ContentView()
}

#Preview("Gameplay View") {
    ContentView(previewPopup: .gameplay)
}

#Preview("SplitMet") {
    ContentView(previewPopup: .splitMet)
}

#Preview("Victory Popup") {
    ContentView(previewShowVictoryPopup: true)
}

#Preview("Settings Popup") {
    ContentView(previewPopup: .settings)
}

#Preview("Stats Popup") {
    ContentView(previewPopup: .stats)
}

#Preview("Intro Popup") {
    ContentView(previewPopup: .intro)
}
