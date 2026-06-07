#!/usr/bin/env node

const { loadLevelsDocument, saveLevelsDocument, loadScheduleEntries, levelsPath } = require("./levels-json");

function getLevelID(level, index) {
    return level.ID || level.id || `level-${index + 1}`;
}

function deriveGoldWord(level) {
    const answers = Array.isArray(level.answers) ? level.answers : [];
    const letters = [];

    for (const answer of answers) {
        const text = String(answer);
        for (let i = 1; i < text.length; i += 1) {
            if (text[i] !== "*") continue;
            const previous = text[i - 1];
            if (!/[A-Za-z]/.test(previous)) continue;
            letters.push(previous.toUpperCase());
        }
    }

    return letters.join("");
}

function main() {
    const { version, levels } = loadLevelsDocument();
    const schedule = loadScheduleEntries();

    const scheduledIDsInOrder = [];
    const seenScheduledIDs = new Set();
    for (const entry of schedule) {
        const id = String(entry.ID || "").trim();
        if (!id || seenScheduledIDs.has(id)) continue;
        seenScheduledIDs.add(id);
        scheduledIDsInOrder.push(id);
    }

    const levelsByID = new Map();
    levels.forEach((level, index) => {
        levelsByID.set(getLevelID(level, index), level);
    });

    levels.forEach((level, index) => {
        const id = getLevelID(level, index);
        level.GOLD_WORD = deriveGoldWord(level);
        if (typeof level.NOTE !== "string") level.NOTE = "";
        level.SCHEDULED = seenScheduledIDs.has(id);
        delete level.ACTIVE;
    });

    const activeLevels = scheduledIDsInOrder.map((id) => levelsByID.get(id)).filter(Boolean);
    const activeLevelSet = new Set(activeLevels);
    const inactiveLevels = levels.filter((level) => !activeLevelSet.has(level));
    const sortedLevels = [...activeLevels, ...inactiveLevels];

    saveLevelsDocument(sortedLevels, version);

    console.log(`Updated ${levelsPath}`);
    console.log(`Scheduled levels (SCHEDULED: true): ${activeLevels.length}`);
    console.log(`Unscheduled levels (SCHEDULED: false): ${inactiveLevels.length}`);
}

try {
    main();
} catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
}
