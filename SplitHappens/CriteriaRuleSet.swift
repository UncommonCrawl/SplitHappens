import Foundation

struct CriteriaRuleSet: Decodable {
    let includeToken: String
    let includeTab: String
    let doubleToken: String
    let doubleTab: String
    let startToken: String
    let startTab: String
    let endToken: String
    let endTab: String
    let containsToken: String
    let containsTab: String
    let rowLabel: String
    let anyRowLabel: String
    let multiRowLabel: String
    let anyRowTokenPlaceholder: String
    let anyLetterLabel: String
    let anyLetterTokenPlaceholder: String
    let customToken: String
    let customTab: String

    static let current = CriteriaRuleSet(
        includeToken: "INCLUDES_[WORD]",
        includeTab: "ONE WORD IS '[WORD]'",
        doubleToken: "[ROW|*|2X]_DOUBLE_[LETTER|* optional]_[NONE] optional",
        doubleTab: "[ROW] HAS DOUBLE '[LETTER]'",
        startToken: "[ROW|*|2X]_STARTS_[STRING|*|2STRING]_[NONE] optional",
        startTab: "[ROW] STARTS WITH '[STRING]'",
        endToken: "[ROW|*|2X]_ENDS_[STRING|*|2STRING]_[NONE] optional",
        endTab: "[ROW] ENDS IN '[STRING]'",
        containsToken: "[ROW|*|2X]_CONTAINS_[STRING|*|2STRING]_[NONE] optional",
        containsTab: "[ROW] CONTAINS '[STRING]'",
        rowLabel: "ROW [ROW_NUMBER]",
        anyRowLabel: "ANY ROW",
        multiRowLabel: "[COUNT] ROWS",
        anyRowTokenPlaceholder: "*",
        anyLetterLabel: "LETTER",
        anyLetterTokenPlaceholder: "*",
        customToken: "ANY OTHER TEXT",
        customTab: "Displays exactly as written"
    )

    static let fallback = current

    func includeLabel(word: String) -> String {
        includeTab.replacingOccurrences(of: "[WORD]", with: word)
    }

    func doubleLabel(row: String, letter: String) -> String {
        let label = doubleTab
            .replacingOccurrences(of: "[ROW]", with: row)
            .replacingOccurrences(of: "[LETTER]", with: letter)
        return unquotedPlaceholderLabel(
            from: pluralAdjustedLabel(label, row: row),
            placeholderValue: letter
        )
    }

    func startLabel(row: String, text: String) -> String {
        let label = startTab
            .replacingOccurrences(of: "[ROW]", with: row)
            .replacingOccurrences(of: "[STRING]", with: text)
        return unquotedPlaceholderLabel(
            from: pluralAdjustedLabel(label, row: row),
            placeholderValue: text
        )
    }

    func endLabel(row: String, text: String) -> String {
        let label = endTab
            .replacingOccurrences(of: "[ROW]", with: row)
            .replacingOccurrences(of: "[STRING]", with: text)
        return unquotedPlaceholderLabel(
            from: pluralAdjustedLabel(label, row: row),
            placeholderValue: text
        )
    }

    func containsLabel(row: String, text: String) -> String {
        let label = containsTab
            .replacingOccurrences(of: "[ROW]", with: row)
            .replacingOccurrences(of: "[STRING]", with: text)
        return unquotedPlaceholderLabel(
            from: pluralAdjustedLabel(label, row: row),
            placeholderValue: text
        )
    }

    func negatedLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: " MUST ", with: " MUST NOT ")
            .replacingOccurrences(of: "ANY", with: "NO")
    }

    func rowText(_ rowNumber: Int?, matchCount: Int = 1) -> String {
        if matchCount > 1 {
            return multiRowLabel.replacingOccurrences(of: "[COUNT]", with: String(matchCount))
        }
        guard let rowNumber else { return anyRowLabel }
        return rowLabel.replacingOccurrences(of: "[ROW_NUMBER]", with: String(rowNumber))
    }

    private func unquotedPlaceholderLabel(from label: String, placeholderValue: String) -> String {
        guard isAnyLetterPlaceholder(placeholderValue) else { return label }
        return label.replacingOccurrences(of: "'\(placeholderValue)'", with: placeholderValue)
    }

    private func pluralAdjustedLabel(_ label: String, row: String) -> String {
        guard row.uppercased().contains("ROWS") else { return label }
        return label
            .replacingOccurrences(of: " HAS ", with: " HAVE ")
            .replacingOccurrences(of: " STARTS ", with: " START ")
            .replacingOccurrences(of: " ENDS ", with: " END ")
            .replacingOccurrences(of: " CONTAINS ", with: " CONTAIN ")
    }

    private func isAnyLetterPlaceholder(_ value: String) -> Bool {
        let normalizedValue = value.uppercased()
        let normalizedToken = anyLetterLabel.uppercased()

        if normalizedValue == normalizedToken {
            return true
        }

        guard normalizedValue.hasSuffix(normalizedToken) else { return false }
        let numericPrefix = normalizedValue.dropLast(normalizedToken.count)
        return !numericPrefix.isEmpty && numericPrefix.allSatisfy(\.isNumber)
    }
}
