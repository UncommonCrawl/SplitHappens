#!/usr/bin/env node

const { loadLevelsDocument } = require("./levels-json");

const VOWELS = new Set(["A", "E", "I", "O", "U", "Y"]);

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

function countLetters(words) {
    let total = 0;
    let vowels = 0;

    words.forEach((word) => {
        for (const char of word) {
            if (char < "A" || char > "Z") {
                continue;
            }
            total += 1;
            if (VOWELS.has(char)) {
                vowels += 1;
            }
        }
    });

    return { total, vowels };
}

function formatRatio(vowels, total) {
    if (total === 0) {
        return "0.0000";
    }
    return (vowels / total).toFixed(4);
}

function main() {
    const { levels } = loadLevelsDocument();

    console.log("index\tid\tvowels\ttotal\tratio");
    levels.forEach((level, index) => {
        const words = getSourceWords(level);
        const { total, vowels } = countLetters(words);
        const ratio = formatRatio(vowels, total);
        console.log(`${index + 1}\t${getLevelId(level, index)}\t${vowels}\t${total}\t${ratio}`);
    });
}

main();
