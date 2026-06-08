#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { execFileSync } = require("child_process");
const { loadLevelsDocument, saveLevelsDocument } = require("./levels-json");

const projectRoot = path.resolve(__dirname, "..");
const levelsNeedsCorrectionPath = path.join(projectRoot, "SplitHappens", "levels_needs_correction.js");
const reportsDir = path.join(projectRoot, "SplitHappens", "import_reports");
const quarantineScriptPath = path.join(projectRoot, "scripts", "quarantine-malformed-levels.js");
const validateScriptPath = path.join(projectRoot, "scripts", "check-levels.js");
const VOWELS = new Set(["A", "E", "I", "O", "U", "Y"]);

function usage() {
    console.log("Usage: ./import-levels <path-to-raw-levels.txt>");
}

function normalizeRawText(text) {
    return text
        .replace(/[“”]/g, "\"")
        .replace(/[‘’]/g, "'")
        .replace(/[–—]/g, "-")
        .replace(/…/g, "...")
        .replace(/\u00A0/g, " ");
}

function loadExportedArray(filePath, exportName) {
    if (!fs.existsSync(filePath)) return [];
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
            typeof item === "string" || typeof item === "number" || typeof item === "boolean" || item === null
        ));
        if (isPrimitiveArray) return `[${value.map(primitiveToString).join(",")}]`;
        if (!value.length) return "[]";
        return `[\n${value.map((item) => `${nestedIndent}${formatValue(item, indentLevel + 1)}`).join(",\n")}\n${indent}]`;
    }
    if (value && typeof value === "object") {
        const entries = Object.entries(value);
        if (!entries.length) return "{}";
        return `{\n${entries.map(([k, v]) => `${nestedIndent}${k}: ${formatValue(v, indentLevel + 1)}`).join(",\n")}\n${indent}}`;
    }
    return primitiveToString(value);
}

function formatExport(name, entries) {
    return `export const ${name} = [\n${entries.map((entry) => `  ${formatValue(entry, 1)}`).join(",\n")}\n];\n`;
}

function normalizeWord(word) {
    return String(word).toUpperCase().replace(/[^A-Z*]/g, "");
}

function cleanId(raw) {
    return String(raw || "")
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9-]+/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "");
}

function countLetters(words, { ignoreAsterisks = false } = {}) {
    const counts = new Map();
    words.forEach((word) => {
        for (const ch of normalizeWord(word)) {
            if (ignoreAsterisks && ch === "*") continue;
            if (ch < "A" || ch > "Z") continue;
            counts.set(ch, (counts.get(ch) || 0) + 1);
        }
    });
    return counts;
}

function letterCountDiffs(sourceWords, answerWords) {
    const sourceCounts = countLetters(sourceWords);
    const targetCounts = countLetters(answerWords, { ignoreAsterisks: true });
    const letters = new Set([...sourceCounts.keys(), ...targetCounts.keys()]);
    const diffs = [];
    [...letters].sort().forEach((letter) => {
        const sourceCount = sourceCounts.get(letter) || 0;
        const targetCount = targetCounts.get(letter) || 0;
        if (sourceCount !== targetCount) {
            diffs.push(`${letter}: source=${sourceCount}, target=${targetCount}`);
        }
    });
    return diffs;
}

function deriveGoldWord(answers) {
    const letters = [];
    answers.forEach((answer) => {
        const text = String(answer).toUpperCase();
        for (let i = 1; i < text.length; i += 1) {
            if (text[i] === "*" && /[A-Z]/.test(text[i - 1])) letters.push(text[i - 1]);
        }
    });
    return letters.join("");
}

function calculateVowelRatio(sourceWords) {
    let total = 0;
    let vowels = 0;
    sourceWords.forEach((word) => {
        for (const char of normalizeWord(word)) {
            if (char < "A" || char > "Z") continue;
            total += 1;
            if (VOWELS.has(char)) vowels += 1;
        }
    });
    return total === 0 ? 0 : Number((vowels / total).toFixed(4));
}

function enrichLevel(seed) {
    const source = seed.source.map(normalizeWord).filter(Boolean);
    const answers = seed.answers.map(normalizeWord).filter(Boolean);
    const diffs = letterCountDiffs(source, answers);
    if (diffs.length > 0) {
        throw new Error(`source/answer letter mismatch (${diffs.join("; ")})`);
    }
    return {
        ID: seed.ID,
        SCHEDULED: true,
        SOURCE_WORD_COUNT: source.length,
        SOURCE_WORD_LENGTHS: source.map((word) => word.length),
        TARGET_ROW_COUNT: answers.length,
        TARGET_ROW_LENGTHS: answers.map((word) => word.replace(/\*/g, "").length),
        source,
        VOWEL_RATIO: calculateVowelRatio(source),
        answers,
        GOLD_WORD: deriveGoldWord(answers),
        CRITERIA_REGULAR: "[ROWS COMPLETED]/[TOTAL ROWS] WORDS",
        CRITERIA_PERFECT: `GOLD TILES SPELL ${deriveGoldWord(answers)} IN ORDER`,
        NOTE: String(seed.NOTE || "")
    };
}

function parseArrayField(block, key) {
    const match = block.match(new RegExp(`${key}\\s*:\\s*\\[([\\s\\S]*?)\\]`));
    if (!match) return null;
    const values = [];
    const rx = /"([^"\\]*(?:\\.[^"\\]*)*)"/g;
    let m;
    while ((m = rx.exec(match[1])) !== null) {
        values.push(m[1]);
    }
    return values;
}

function parseStringField(block, key) {
    const match = block.match(new RegExp(`${key}\\s*:\\s*"([^"\\n\\r]*)"`));
    return match ? match[1] : null;
}

function splitObjectBlocks(raw) {
    const blocks = [];
    let depth = 0;
    let inString = false;
    let escaping = false;
    let start = -1;
    for (let i = 0; i < raw.length; i += 1) {
        const ch = raw[i];
        if (inString) {
            if (escaping) {
                escaping = false;
            } else if (ch === "\\") {
                escaping = true;
            } else if (ch === "\"") {
                inString = false;
            }
            continue;
        }
        if (ch === "\"") {
            inString = true;
            continue;
        }
        if (ch === "{") {
            if (depth === 0) start = i;
            depth += 1;
        } else if (ch === "}") {
            depth -= 1;
            if (depth === 0 && start >= 0) {
                blocks.push(raw.slice(start, i + 1));
                start = -1;
            }
        }
    }
    return blocks;
}

function parseSeed(block) {
    const idRaw = parseStringField(block, "ID");
    const source = parseArrayField(block, "source");
    const answers = parseArrayField(block, "answers");
    const note = parseStringField(block, "NOTE") || "";

    const ID = cleanId(idRaw);
    const cleanedSource = (source || []).map(normalizeWord).filter(Boolean);
    const cleanedAnswers = (answers || []).map(normalizeWord).filter(Boolean);

    if (!ID || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(ID)) {
        return { ok: false, id: idRaw || "(unknown)", reason: "missing/invalid ID" };
    }
    if (!cleanedSource.length) return { ok: false, id: ID, reason: "missing/invalid source array" };
    if (!cleanedAnswers.length) return { ok: false, id: ID, reason: "missing/invalid answers array" };

    return {
        ok: true,
        seed: { ID, source: cleanedSource, answers: cleanedAnswers, NOTE: note }
    };
}

function run() {
    const inputPathArg = process.argv[2];
    if (!inputPathArg) {
        usage();
        process.exit(1);
    }

    const inputPath = path.resolve(process.cwd(), inputPathArg);
    if (!fs.existsSync(inputPath)) {
        console.error(`Input file not found: ${inputPath}`);
        process.exit(1);
    }

    const raw = fs.readFileSync(inputPath, "utf8");
    const normalizedRaw = normalizeRawText(raw);
    const blocks = splitObjectBlocks(normalizedRaw);

    const parseFailures = [];
    const parsedSeeds = [];
    blocks.forEach((block) => {
        const result = parseSeed(block);
        if (!result.ok) {
            parseFailures.push({ id: result.id, reason: result.reason });
            return;
        }
        parsedSeeds.push(result.seed);
    });

    const levelDocument = loadLevelsDocument();
    const levels = levelDocument.levels;
    const correction = loadExportedArray(levelsNeedsCorrectionPath, "levelsNeedsCorrection");
    const existingIds = new Set(levels.map((level, index) => level.ID || level.id || `level-${index + 1}`));
    const correctionIds = new Set(correction.map((level, index) => level.ID || level.id || `level-${index + 1}`));
    const seenIncoming = new Set();

    const imported = [];
    const quarantined = [];
    const droppedDuplicateIds = [];

    parsedSeeds.forEach((seed) => {
        if (existingIds.has(seed.ID) || correctionIds.has(seed.ID) || seenIncoming.has(seed.ID)) {
            droppedDuplicateIds.push(seed.ID);
            return;
        }
        seenIncoming.add(seed.ID);

        try {
            imported.push(enrichLevel(seed));
        } catch (error) {
            quarantined.push({
                ID: seed.ID,
                source: seed.source,
                answers: seed.answers,
                CORRECTION_NOTE: `AUTO_MOVED_FOR_CORRECTION: ${error.message}`
            });
        }
    });

    if (imported.length > 0) {
        saveLevelsDocument([...levels, ...imported], levelDocument.version);
    }
    if (quarantined.length > 0 || parseFailures.length > 0) {
        const parseFailureEntries = parseFailures.map((failure) => ({
            ID: failure.id,
            source: [],
            answers: [],
            CORRECTION_NOTE: `AUTO_MOVED_FOR_CORRECTION: ${failure.reason}`
        }));
        fs.writeFileSync(
            levelsNeedsCorrectionPath,
            formatExport("levelsNeedsCorrection", [...correction, ...quarantined, ...parseFailureEntries])
        );
    }

    execFileSync("node", [quarantineScriptPath], { stdio: "inherit" });

    let validateExitCode = 0;
    try {
        execFileSync("node", [validateScriptPath], { stdio: "inherit" });
    } catch (error) {
        validateExitCode = typeof error.status === "number" ? error.status : 1;
    }

    fs.mkdirSync(reportsDir, { recursive: true });
    const timestamp = new Date().toISOString().replace(/[:]/g, "-");
    const reportPath = path.join(reportsDir, `import-report-${timestamp}.json`);
    const report = {
        createdAt: new Date().toISOString(),
        inputPath,
        objectBlocksFound: blocks.length,
        parsedCandidates: parsedSeeds.length,
        importedIds: imported.map((level) => level.ID),
        droppedDuplicateIds,
        quarantinedIds: quarantined.map((level) => level.ID),
        parseFailures
    };
    fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");

    console.log("");
    console.log(`Imported: ${imported.length}`);
    console.log(`Dropped duplicate IDs: ${droppedDuplicateIds.length}`);
    console.log(`Quarantined: ${quarantined.length + parseFailures.length}`);
    console.log(`Report: ${reportPath}`);

    if (validateExitCode !== 0) {
        process.exitCode = validateExitCode;
    }
}

run();
