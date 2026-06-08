#!/usr/bin/env node

const { loadLevelsDocument, levelsPath } = require("./levels-json");

const { levels } = loadLevelsDocument();

function getLevelId(level, index) {
    return level.ID || level.id || `level-${index + 1}`;
}

function getSourceWords(level) {
    if (Array.isArray(level.source)) {
        return level.source.map((word) => String(word).toUpperCase());
    }
    if (Array.isArray(level.STARTING_WORDS)) {
        return level.STARTING_WORDS.map((word) => String(word).toUpperCase());
    }
    return [];
}

function getTargetWords(level) {
    const candidateArrays = [level.answers, level.TARGET_WORDS, level.targetWords];
    const words = candidateArrays.find(Array.isArray);
    if (!Array.isArray(words)) {
        return [];
    }
    return words.map((word) => String(word).toUpperCase());
}

function normalizeTargetWord(word) {
    return String(word).toUpperCase().replace(/\*/g, "");
}

function deriveGoldWord(words) {
    const letters = [];
    words.forEach((rawWord) => {
        const word = String(rawWord).toUpperCase();
        for (let i = 1; i < word.length; i += 1) {
            if (word[i] === "*" && /[A-Z]/.test(word[i - 1])) {
                letters.push(word[i - 1]);
            }
        }
    });
    return letters.join("");
}

function countLetters(words, { ignoreAsterisks = false } = {}) {
    const counts = new Map();
    words.forEach((rawWord) => {
        const word = String(rawWord).toUpperCase();
        for (const char of word) {
            if (ignoreAsterisks && char === "*") {
                continue;
            }
            if (char < "A" || char > "Z") {
                continue;
            }
            counts.set(char, (counts.get(char) || 0) + 1);
        }
    });
    return counts;
}

function mapDiff(sourceCounts, targetCounts) {
    const letters = new Set([...sourceCounts.keys(), ...targetCounts.keys()]);
    const diffs = [];

    [...letters].sort().forEach((letter) => {
        const sourceCount = sourceCounts.get(letter) || 0;
        const targetCount = targetCounts.get(letter) || 0;
        if (sourceCount === targetCount) {
            return;
        }
        diffs.push({
            letter,
            sourceCount,
            targetCount
        });
    });

    return diffs;
}

function countNonOverlapping(word, fragment) {
    if (!fragment) {
        return 0;
    }

    let count = 0;
    let index = 0;

    while (index < word.length) {
        const foundAt = word.indexOf(fragment, index);
        if (foundAt === -1) {
            break;
        }
        count += 1;
        index = foundAt + fragment.length;
    }

    return count;
}

function containsDoubleLetter(word, letter) {
    for (let i = 0; i < word.length - 1; i += 1) {
        const lhs = word[i];
        const rhs = word[i + 1];
        if (lhs !== rhs) {
            continue;
        }
        if (!letter) {
            return true;
        }
        if (lhs === letter) {
            return true;
        }
    }
    return false;
}

function parseRowToken(rowToken) {
    if (rowToken === "ANY" || rowToken === "*") {
        return { rowNumber: null, requiredRowMatchCount: 1 };
    }
    if (/^[1-9]\d*X$/.test(rowToken)) {
        return { rowNumber: null, requiredRowMatchCount: Number(rowToken.slice(0, -1)) };
    }
    if (/^[1-9]\d*$/.test(rowToken)) {
        return { rowNumber: Number(rowToken), requiredRowMatchCount: 1 };
    }
    return null;
}

function stripNegation(components) {
    const result = [...components];
    let isNegated = false;
    while (result.length > 0 && result[result.length - 1] === "NONE") {
        isNegated = true;
        result.pop();
    }
    return { components: result, isNegated };
}

function parseRowLetterQualifier(suffix) {
    const splitResult = stripNegation(suffix.split("_"));
    const components = splitResult.components;
    const isNegated = splitResult.isNegated;

    if (components.length < 1 || components.length > 2) {
        return null;
    }

    const parsedRow = parseRowToken(components[0]);
    if (!parsedRow) {
        return null;
    }

    let letter = null;
    if (components.length === 2) {
        const letterToken = components[1];
        if (letterToken !== "ANY" && letterToken !== "*") {
            if (!/^[A-Z]$/.test(letterToken)) {
                return null;
            }
            letter = letterToken;
        }
    }

    return {
        ...parsedRow,
        letter,
        isNegated
    };
}

function parseRowTextQualifier(suffix) {
    const splitResult = stripNegation(suffix.split("_"));
    const components = splitResult.components;
    const isNegated = splitResult.isNegated;

    if (components.length < 2) {
        return null;
    }

    const parsedRow = parseRowToken(components[0]);
    if (!parsedRow) {
        return null;
    }

    const textToken = components.slice(1).join("_");
    let text = null;
    let requiredTextInstanceCount = 1;

    if (textToken !== "ANY" && textToken !== "*") {
        if (!textToken) {
            return null;
        }
        const digitPrefix = textToken.match(/^\d+/)?.[0];
        if (digitPrefix) {
            requiredTextInstanceCount = Number(digitPrefix);
            text = textToken.slice(digitPrefix.length);
            if (!text || requiredTextInstanceCount < 1) {
                return null;
            }
        } else {
            text = textToken;
        }
    }

    return {
        ...parsedRow,
        text,
        requiredTextInstanceCount,
        isNegated
    };
}

function parseRowFirstCriterion(criterion) {
    const components = criterion.split("_");
    if (components.length < 2) {
        return null;
    }

    const parsedRow = parseRowToken(components[0]);
    if (!parsedRow) {
        return null;
    }

    const operator = components[1];
    const suffix = [components[0], ...components.slice(2)].join("_");

    if (operator === "DOUBLE") {
        const qualifier = parseRowLetterQualifier(suffix);
        return qualifier ? { type: "double", qualifier } : null;
    }
    if (operator === "START" || operator === "STARTS") {
        const qualifier = parseRowTextQualifier(suffix);
        return qualifier ? { type: "starts", qualifier } : null;
    }
    if (operator === "END" || operator === "ENDS") {
        const qualifier = parseRowTextQualifier(suffix);
        return qualifier ? { type: "ends", qualifier } : null;
    }
    if (operator === "CONTAINS") {
        const qualifier = parseRowTextQualifier(suffix);
        return qualifier ? { type: "contains", qualifier } : null;
    }

    return null;
}

function parseCriterion(rawCriterion) {
    if (typeof rawCriterion !== "string") {
        return null;
    }

    const criterion = rawCriterion.trim().toUpperCase();
    if (!criterion) {
        return null;
    }

    if (criterion === "[ROWS COMPLETED]/[TOTAL ROWS] WORDS") {
        return { type: "progress" };
    }

    if (criterion.startsWith("INCLUDES_") || criterion.startsWith("INCLUDE_")) {
        const prefix = criterion.startsWith("INCLUDES_") ? "INCLUDES_" : "INCLUDE_";
        const word = criterion.slice(prefix.length);
        if (!word) {
            return null;
        }
        return { type: "include", word };
    }

    const rowFirst = parseRowFirstCriterion(criterion);
    if (rowFirst) {
        return rowFirst;
    }

    if (criterion.startsWith("DOUBLE_")) {
        const qualifier = parseRowLetterQualifier(criterion.slice("DOUBLE_".length));
        return qualifier ? { type: "double", qualifier } : null;
    }
    if (criterion.startsWith("STARTS_") || criterion.startsWith("START_")) {
        const prefix = criterion.startsWith("STARTS_") ? "STARTS_" : "START_";
        const qualifier = parseRowTextQualifier(criterion.slice(prefix.length));
        return qualifier ? { type: "starts", qualifier } : null;
    }
    if (criterion.startsWith("ENDS_") || criterion.startsWith("END_")) {
        const prefix = criterion.startsWith("ENDS_") ? "ENDS_" : "END_";
        const qualifier = parseRowTextQualifier(criterion.slice(prefix.length));
        return qualifier ? { type: "ends", qualifier } : null;
    }
    if (criterion.startsWith("CONTAINS_")) {
        const qualifier = parseRowTextQualifier(criterion.slice("CONTAINS_".length));
        return qualifier ? { type: "contains", qualifier } : null;
    }

    return { type: "unsupported", raw: criterion };
}

function matchingWords(words, rowNumber) {
    if (rowNumber == null) {
        return [...words];
    }
    if (rowNumber >= 1 && rowNumber <= words.length) {
        return [words[rowNumber - 1]];
    }
    return [];
}

function hasRequiredMatches(words, qualifier, predicate) {
    const matchingCount = matchingWords(words, qualifier.rowNumber)
        .filter(predicate)
        .length;

    if (qualifier.isNegated) {
        return matchingCount === 0;
    }
    return matchingCount >= qualifier.requiredRowMatchCount;
}

function evaluateCriterion(parsedCriterion, words) {
    switch (parsedCriterion.type) {
    case "progress":
        return true;
    case "include":
        return words.includes(parsedCriterion.word);
    case "double":
        return hasRequiredMatches(
            words,
            parsedCriterion.qualifier,
            (word) => containsDoubleLetter(word, parsedCriterion.qualifier.letter)
        );
    case "starts":
        return hasRequiredMatches(words, parsedCriterion.qualifier, (word) => {
            if (!parsedCriterion.qualifier.text) {
                return word.length > 0;
            }
            const repeated = parsedCriterion.qualifier.text.repeat(parsedCriterion.qualifier.requiredTextInstanceCount);
            return word.startsWith(repeated);
        });
    case "ends":
        return hasRequiredMatches(words, parsedCriterion.qualifier, (word) => {
            if (!parsedCriterion.qualifier.text) {
                return word.length > 0;
            }
            const repeated = parsedCriterion.qualifier.text.repeat(parsedCriterion.qualifier.requiredTextInstanceCount);
            return word.endsWith(repeated);
        });
    case "contains":
        return hasRequiredMatches(words, parsedCriterion.qualifier, (word) => {
            if (!parsedCriterion.qualifier.text) {
                return word.length > 0;
            }
            return countNonOverlapping(word, parsedCriterion.qualifier.text) >= parsedCriterion.qualifier.requiredTextInstanceCount;
        });
    case "unsupported":
        return null;
    default:
        return null;
    }
}

const check1Failures = [];
const check1Skipped = [];
levels.forEach((level, index) => {
    const levelId = getLevelId(level, index);
    const sourceWords = getSourceWords(level);
    const targetWords = getTargetWords(level);

    if (sourceWords.length === 0 || targetWords.length === 0) {
        check1Skipped.push({
            levelId,
            reason: "missing source words or target words"
        });
        return;
    }

    const sourceCounts = countLetters(sourceWords);
    const targetCounts = countLetters(targetWords, { ignoreAsterisks: true });
    const diffs = mapDiff(sourceCounts, targetCounts);
    if (diffs.length > 0) {
        check1Failures.push({
            levelId,
            diffs
        });
    }
});

const targetWordOccurrences = new Map();
levels.forEach((level, index) => {
    const levelId = getLevelId(level, index);
    const targetWords = getTargetWords(level);
    targetWords.forEach((word, rowIndex) => {
        const normalizedWord = normalizeTargetWord(word);
        if (!normalizedWord) {
            return;
        }

        if (!targetWordOccurrences.has(normalizedWord)) {
            targetWordOccurrences.set(normalizedWord, []);
        }

        targetWordOccurrences.get(normalizedWord).push({
            levelIndex: index,
            levelId,
            rowIndex
        });
    });
});

const check2Duplicates = [];
for (const [word, occurrences] of targetWordOccurrences.entries()) {
    const uniqueLevels = new Set(occurrences.map((occurrence) => occurrence.levelIndex));
    if (uniqueLevels.size > 1) {
        check2Duplicates.push({ word, occurrences });
    }
}
check2Duplicates.sort((lhs, rhs) => lhs.word.localeCompare(rhs.word));

const check3Failures = [];
levels.forEach((level, index) => {
    const levelId = getLevelId(level, index);
    const targetWords = getTargetWords(level);
    const goldWord = deriveGoldWord(targetWords);
    const expectedPerfect = `GOLD TILES SPELL ${goldWord} IN ORDER`;

    if (level.CRITERIA_REGULAR !== "[ROWS COMPLETED]/[TOTAL ROWS] WORDS") {
        check3Failures.push({
            levelId,
            field: "CRITERIA_REGULAR",
            expected: "[ROWS COMPLETED]/[TOTAL ROWS] WORDS",
            actual: level.CRITERIA_REGULAR
        });
    }
    if (level.GOLD_WORD !== goldWord) {
        check3Failures.push({
            levelId,
            field: "GOLD_WORD",
            expected: goldWord,
            actual: level.GOLD_WORD
        });
    }
    if (level.CRITERIA_PERFECT !== expectedPerfect) {
        check3Failures.push({
            levelId,
            field: "CRITERIA_PERFECT",
            expected: expectedPerfect,
            actual: level.CRITERIA_PERFECT
        });
    }
});

console.log(`Checked ${levels.length} level(s) from ${levelsPath}`);
console.log("");

console.log("1) Source letters match target letters");
if (check1Failures.length === 0) {
    console.log(`PASS (${levels.length - check1Skipped.length} checked, ${check1Skipped.length} skipped)`);
} else {
    console.log(`FAIL (${check1Failures.length} level(s) mismatched, ${check1Skipped.length} skipped)`);
    check1Failures.forEach((failure) => {
        const diffText = failure.diffs
            .map((diff) => `${diff.letter}: source=${diff.sourceCount}, target=${diff.targetCount}`)
            .join("; ");
        console.log(`- ${failure.levelId}: ${diffText}`);
    });
}
if (check1Skipped.length > 0) {
    check1Skipped.forEach((skipped) => {
        console.log(`- ${skipped.levelId}: skipped (${skipped.reason})`);
    });
}
console.log("");

console.log("2) Target words repeated across levels (ignoring *)");
if (check2Duplicates.length === 0) {
    console.log("PASS (no repeated target words across levels)");
} else {
    console.log(`FAIL (${check2Duplicates.length} repeated target word(s))`);
    check2Duplicates.forEach((duplicate) => {
        const where = duplicate.occurrences
            .map((occurrence) => `${occurrence.levelId}#${occurrence.rowIndex + 1}`)
            .join(", ");
        console.log(`- ${duplicate.word}: ${where}`);
    });
}
console.log("");

console.log("3) Named criteria match the level answer key");
if (check3Failures.length === 0) {
    console.log(`PASS (${levels.length} checked)`);
} else {
    console.log(`FAIL (${check3Failures.length} criteria mismatch(es))`);
    check3Failures.forEach((failure) => {
        console.log(`- ${failure.levelId}: ${failure.field} expected "${failure.expected}", found "${failure.actual}"`);
    });
}
console.log("");

const hasFailures = check1Failures.length > 0 || check2Duplicates.length > 0 || check3Failures.length > 0;
if (hasFailures) {
    process.exitCode = 1;
}
