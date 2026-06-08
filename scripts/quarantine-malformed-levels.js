#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { loadLevelsDocument, saveLevelsDocument } = require("./levels-json");

const projectRoot = path.resolve(__dirname, "..");
const levelsNeedsCorrectionPath = path.join(projectRoot, "SplitHappens", "levels_needs_correction.js");

function loadExportedArray(filePath, exportName) {
    if (!fs.existsSync(filePath)) {
        return [];
    }
    const source = fs.readFileSync(filePath, "utf8");
    const normalized = source.replace(
        new RegExp(`^\\s*export\\s+const\\s+${exportName}\\s*=\\s*`),
        `${exportName} = `
    );
    const context = { [exportName]: [] };
    vm.createContext(context);
    vm.runInContext(normalized, context, { filename: filePath });
    if (!Array.isArray(context[exportName])) {
        throw new Error(`${path.basename(filePath)} did not produce a ${exportName} array.`);
    }
    return context[exportName];
}

function primitiveToString(value) {
    if (typeof value === "string") return JSON.stringify(value);
    if (typeof value === "number" || typeof value === "boolean") return String(value);
    if (value === null) return "null";
    return JSON.stringify(value);
}

function formatValue(value, indentLevel) {
    const indent = "  ".repeat(indentLevel);
    const nestedIndent = "  ".repeat(indentLevel + 1);

    if (Array.isArray(value)) {
        const isPrimitiveArray = value.every((item) => (
            typeof item === "string" ||
            typeof item === "number" ||
            typeof item === "boolean" ||
            item === null
        ));
        if (isPrimitiveArray) {
            return `[${value.map(primitiveToString).join(",")}]`;
        }
        if (value.length === 0) {
            return "[]";
        }
        const lines = value.map((item) => `${nestedIndent}${formatValue(item, indentLevel + 1)}`);
        return `[\n${lines.join(",\n")}\n${indent}]`;
    }

    if (value && typeof value === "object") {
        const entries = Object.entries(value);
        if (entries.length === 0) {
            return "{}";
        }
        const lines = entries.map(([key, nestedValue]) => (
            `${nestedIndent}${key}: ${formatValue(nestedValue, indentLevel + 1)}`
        ));
        return `{\n${lines.join(",\n")}\n${indent}}`;
    }

    return primitiveToString(value);
}

function formatLevels(name, levels) {
    const body = levels.map((level) => `  ${formatValue(level, 1)}`).join(",\n");
    return `export const ${name} = [\n${body}\n];\n`;
}

function getLevelId(level, index) {
    return level.ID || level.id || `level-${index + 1}`;
}

function isWordArray(value, pattern) {
    return Array.isArray(value) &&
        value.length > 0 &&
        value.every((item) => typeof item === "string" && pattern.test(item));
}

function malformedReason(level) {
    if (!level || typeof level !== "object") {
        return "entry is not an object";
    }
    if (typeof level.ID !== "string" || !level.ID.trim()) {
        return "missing valid ID";
    }
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(level.ID.trim())) {
        return "ID must match lowercase slug format";
    }
    if (level.ID.endsWith("-source")) {
        return "ID appears to be parser artifact";
    }
    if (!isWordArray(level.source, /^[A-Z]+$/)) {
        return "source must be a non-empty array of A-Z words";
    }
    if (!isWordArray(level.answers, /^[A-Z*]+$/)) {
        return "answers must be a non-empty array of A-Z/* words";
    }
    const expectedSourceWordLengths = level.source.map((word) => word.length);
    const expectedTargetRowCount = level.answers.length;
    const expectedTargetRowLengths = level.answers.map((word) => word.replace(/\*/g, "").length);

    if (!Array.isArray(level.SOURCE_WORD_LENGTHS) ||
        JSON.stringify(level.SOURCE_WORD_LENGTHS) !== JSON.stringify(expectedSourceWordLengths)) {
        return "SOURCE_WORD_LENGTHS mismatch";
    }
    if (typeof level.TARGET_ROW_COUNT !== "number" || level.TARGET_ROW_COUNT !== expectedTargetRowCount) {
        return "TARGET_ROW_COUNT mismatch";
    }
    if (!Array.isArray(level.TARGET_ROW_LENGTHS) ||
        JSON.stringify(level.TARGET_ROW_LENGTHS) !== JSON.stringify(expectedTargetRowLengths)) {
        return "TARGET_ROW_LENGTHS mismatch";
    }
    return null;
}

function main() {
    const levelDocument = loadLevelsDocument();
    const levels = levelDocument.levels;
    const needsCorrection = loadExportedArray(levelsNeedsCorrectionPath, "levelsNeedsCorrection");
    const correctionIds = new Set(needsCorrection.map((entry, i) => getLevelId(entry, i)));

    const kept = [];
    const moved = [];

    levels.forEach((level, index) => {
        const reason = malformedReason(level);
        if (!reason) {
            kept.push(level);
            return;
        }

        const levelId = getLevelId(level, index);
        if (!correctionIds.has(levelId)) {
            moved.push({
                ...level,
                CORRECTION_NOTE: `AUTO_MOVED_FOR_CORRECTION: malformed entry (${reason})`
            });
            correctionIds.add(levelId);
        }
    });

    if (moved.length === 0) {
        console.log("No malformed levels found.");
        return;
    }

    saveLevelsDocument(kept, levelDocument.version);
    fs.writeFileSync(
        levelsNeedsCorrectionPath,
        formatLevels("levelsNeedsCorrection", [...needsCorrection, ...moved])
    );

    console.log(`Moved ${moved.length} malformed level(s) to ${path.relative(projectRoot, levelsNeedsCorrectionPath)}.`);
}

main();
