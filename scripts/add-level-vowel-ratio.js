#!/usr/bin/env node

const { loadLevelsDocument, saveLevelsDocument, levelsPath } = require("./levels-json");

const VOWELS = new Set(["A", "E", "I", "O", "U", "Y"]);

function getSourceWords(level) {
    if (Array.isArray(level.source)) return level.source.map((word) => String(word).toUpperCase());
    if (Array.isArray(level.STARTING_WORDS)) return level.STARTING_WORDS.map((word) => String(word).toUpperCase());
    return [];
}

function calculateVowelRatio(words) {
    let total = 0;
    let vowels = 0;
    for (const word of words) {
        for (const char of String(word).toUpperCase()) {
            if (char < "A" || char > "Z") continue;
            total += 1;
            if (VOWELS.has(char)) vowels += 1;
        }
    }
    return total === 0 ? 0 : Number((vowels / total).toFixed(4));
}

function withVowelRatio(level) {
    const ratio = calculateVowelRatio(getSourceWords(level));
    const entries = Object.entries(level).filter(([key]) => key !== "VOWEL_RATIO");
    const rebuiltEntries = [];
    let inserted = false;

    entries.forEach(([key, value]) => {
        rebuiltEntries.push([key, value]);
        if (key === "source") {
            rebuiltEntries.push(["VOWEL_RATIO", ratio]);
            inserted = true;
        }
    });

    if (!inserted) rebuiltEntries.push(["VOWEL_RATIO", ratio]);
    return Object.fromEntries(rebuiltEntries);
}

function main() {
    const { version, levels } = loadLevelsDocument();
    saveLevelsDocument(levels.map(withVowelRatio), version);
    console.log(`Updated vowel ratios in ${levelsPath}.`);
}

main();
