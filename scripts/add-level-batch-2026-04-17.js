#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { loadLevelsDocument, saveLevelsDocument } = require("./levels-json");

const VOWELS = new Set(["A", "E", "I", "O", "U", "Y"]);

const NEW_LEVELS = [
    { ID: "crowes", source: ["CAMERON","RUSSELL","JACKDAWS"], answers: ["SLAC*KER","R*O*UNDS","JAW*","CAME*LS*"] },
    { ID: "bobs", source: ["BARKER","BELCHER","SIDESHOW"], answers: ["B*EACH","WO*RLDS","B*EER","HIKERS*"] },
    { ID: "lamborghini", source: ["DIABLO","COUNTACH","MIURA"], answers: ["L*A*UNCH","OM*IT","CRAB*","AUDIO*"] },
    { ID: "atlanta", source: ["FALCONS","OUTKAST","COCACOLA"], answers: ["COA*ST*AL*","SA*CK","COCON*UT*","LOA*F"] },
    { ID: "wutang", source: ["CASHRULES","EVERYTHIN","GAROUNDME"], answers: ["C*RUD","R*EHASH","E*VENING","A*LTER","M*OUSY"] },
    { ID: "punk", source: ["PISTOLS","BUZZCOCKS","RAMONES"], answers: ["CAMP*U*S","SOOT","N*OZZLES","BRICK*S"] },
    { ID: "cairo", source: ["PYRAMIDS","CITADEL","KOSHARI"], answers: ["AID","C*ITY","SHA*KE","SPI*R*AL","DO*RM"] },
    { ID: "popes", source: ["PIUSIX","STPETER","GREGORY"], answers: ["GRIP*","O*YSTER","P*URGE*","EXITS*"] },
    { ID: "plays", source: ["ANTIGONE","PYGMALION","FENCES"], answers: ["OP*TION","CL*EAN","FA*N","GY*M","GENIES*"] },
    { ID: "ballet", source: ["POINTE","ALLEGRO","BARRE"], answers: ["ROB*E","RA*GER","L*ION","L*E*APT*"] },
    { ID: "potato", source: ["TATERTOTS","GNOCCHI","PIEROGI"], answers: ["GOP*HER","IRO*N","T*A*CTIC","GIST*","TO*E"] },
    { ID: "rundmc", source: ["QUEENS","MYADIDAS","ITSTRICKY"], answers: ["AR*K","SQU*IN*T","SID*E","M*ISTY","DEC*AY"] },
    { ID: "bears", source: ["BADNEWS","GRIZZLY","CHICAGO"], answers: ["B*OG","HAZE*","WIZA*R*DS*","CYCLING"] },
    { ID: "venice", source: ["CARNIVAL","CAMPANILE","CICHETTI"], answers: ["CIV*IC","LAME*NT","PIN*I*C","LATC*H","ARE*A"] },
    { ID: "koala", source: ["MARSUPIAL","NOCTURNAL","OUTBACK"], answers: ["SMACK*","CO*RRUPT","OUT","A*NNUAL","BA*IL"] },
    { ID: "muhammad-ali", source: ["LISTON","FRAZIER","FOREMAN"], answers: ["TRA*IN","RAFFL*E","ZOOM","RINSE"] },
    { ID: "oceans-eleven", source: ["CLOONEY","BRADPITT","LASVEGAS"], answers: ["BLO*T","C*ARGO","E*VA*DE","PIN*TS","LAYS*"] },
    { ID: "rem", source: ["GEORGIANS","JANGLEPOP","OUTOFTIME"], answers: ["GR*UNGE","FAJITA","PIGE*ON","TEM*PO","SOLO"] },
    { ID: "ikea", source: ["LOVBACKEN","EKTORP","FARGRIK"], answers: ["CORK","GRI*EF","BALK*","VE*TO","PRA*NK"] },
    { ID: "serena-williams", source: ["GRANDSLAM","TENNIS","GOLDMEDAL"], answers: ["ODDS*","ANTLE*R*","ME*N*D","GLAM","SINGA*L"] },
    { ID: "pastries", source: ["STRUDEL","PALMIER","STICKYBUN"], answers: ["P*UTRID","MENA*CE","LUS*T*","BR*ISKLY*"] },
    { ID: "noun-types", source: ["COMPOUND","COUNTABLE","SINGULAR"], answers: ["MULE","ON*ION","GRO*U*P","BLAN*D","CACTUS*"] },
    { ID: "clubs", source: ["JOYLUCK","CULTURE","BREAKFAST"], answers: ["FAC*T","L*U*CKY","JOKER","RUB*","S*ALUTE"] },
    { ID: "clue", source: ["PROFPLUM","LEADPIPE","KITCHEN"], answers: ["PIC*K","L*EAP","U*PLIFT","NE*ED","MORPH"] },
    { ID: "dans", source: ["MARINO","AYKROYD","STEVENS"], answers: ["D*YES","RA*KER","NAVY","MOTION*S*"] },
    { ID: "mark-twain", source: ["TOMSAWYER","HUCKFINN","TOMCANTY"], answers: ["T*OTEM","FAW*N","CHA*RI*TY","SUNN*Y","MOCK"] },
    { ID: "scots", source: ["WALLACE","STEVENSON","CONNERY"], answers: ["LAWNS*","C*LEVER","CONO*Y","NEAT*ENS*"] },
    { ID: "cathedrals", source: ["NOTREDAME","CHARTRES","COLOGNE"], answers: ["C*A*RGO","T*ENTH*","ONCE*","ORD*ER*","MA*L*ES*"] },
    { ID: "wayne-gretzky", source: ["GRETZKY","EDMONTON","HATTRICKS"], answers: ["ZIG*","TR*E*KS","MA*T*H","CRO*NY","KN*OTTE*D"] },
    { ID: "monopoly", source: ["PARKPLACE","STCHARLES","GOTOJAIL"], answers: ["P*ALA*TE","HACKERS*","JOLTS*","G*RIP","CO*LA"] },
    { ID: "eagle", source: ["CROWNED","GOLDEN","BALD"], answers: ["E*ND","GRA*W","D*LOB","CL*ONE*D"] },
    { ID: "prince", source: ["MINNESOTA","PURPLE","GOCRAZY"], answers: ["P*AUPER*","STI*N*G","C*OZY","LONE*","ARM"] },
    { ID: "caped", source: ["DRACULA","SUPERMAN","ZORRO"], answers: ["C*URL","RA*ZOR","P*AUSE*","RAND*OM"] },
    { ID: "lincoln", source: ["LOGCABIN","ILLINOIS","HONESTABE"], answers: ["SIGNAL*","OBTAI*N*","EC*HO*ES","BILL*ION*"] },
    { ID: "cartoon-cats", source: ["SCRATCHY","SYLVESTER","GARFIELD"], answers: ["C*REDIT","GRA*VY","ARCH","ST*YLES","S*ELF"] },
    { ID: "fondue", source: ["GRUYERE","FONTINA","CHEDDAR"], answers: ["F*RYER","O*AT","GAIN*ED*","CHU*RNE*D"] },
    { ID: "pele", source: ["WORLDCUP","NUMBERTEN","BRAZIL"], answers: ["RUNT","ZAP*","CLOWNE*D","RIB","RUMBL*E*"] },
    { ID: "pie", source: ["KEYLIME","PUMPKIN","CHERRY"], answers: ["LUMP*Y","HYPER","KI*CKER","MINE*"] },
    { ID: "spidey", source: ["KINGPIN","DOCOCK","GWENSTACY"], answers: ["S*P*AT","WI*NING","D*OG","NE*CK","COCKY*"] },
    { ID: "best-picture", source: ["PARASITE","BIRDMAN","CHICAGO"], answers: ["B*RAIN","CHE*MIS*T*","AGO","P*AI*R","C*AD"] },
    { ID: "kpop", source: ["BLACKPINK","SUPERFANS","GOLDEN"], answers: ["LENS","FLICK*ER","P*O*UND","GASP*","BANK"] },
    { ID: "ohtani", source: ["ANGELS","DODGERS","PITCHER"], answers: ["LEDGER","PO*RCH*","ST*A*G","SN*I*DE"] },
    { ID: "bigtop", source: ["MAGICIAN","ACROBATS","TRAPEZE"], answers: ["B*I*AS","G*RAZE","CART*","CO*ME","P*INATA"] },
    { ID: "ahab", source: ["ISHMAEL","STARBUCK","MOBYDICK"], answers: ["A*YE","DISK","CH*UCK","LA*ST","BRIM","MOB*"] },
    { ID: "reef", source: ["ANENOME","STARFISH","SEAHORSE"], answers: ["HAIR*","STE*AM","ONE*","SEASON","F*RESH"] },
    { ID: "thai", source: ["TOMYUM","REDCURRY","FISHSAUCE"], answers: ["MUD","CRUST*Y","H*OUSE","CREA*MY","FI*R"] }
];

const projectRoot = path.resolve(__dirname, "..");
const levelsNeedsCorrectionPath = path.join(projectRoot, "SplitHappens", "levels_needs_correction.js");

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

function formatLevels(levels) {
    const body = levels.map((level) => `  ${formatValue(level, 1)}`).join(",\n");
    return `export const levels = [\n${body}\n];\n`;
}

function formatLevelsNeedsCorrection(levels) {
    const body = levels.map((level) => `  ${formatValue(level, 1)}`).join(",\n");
    return `export const levelsNeedsCorrection = [\n${body}\n];\n`;
}

function getLevelId(level, index) {
    return level.ID || level.id || `level-${index + 1}`;
}

function normalizeWord(word) {
    return String(word).toUpperCase().replace(/[^A-Z*]/g, "");
}

function countLetters(words, { ignoreAsterisks = false } = {}) {
    const counts = new Map();
    words.forEach((word) => {
        for (const char of normalizeWord(word)) {
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
            if (text[i] === "*" && /[A-Z]/.test(text[i - 1])) {
                letters.push(text[i - 1]);
            }
        }
    });
    return letters.join("");
}

function calculateVowelRatio(sourceWords) {
    let total = 0;
    let vowels = 0;
    sourceWords.forEach((word) => {
        for (const char of normalizeWord(word)) {
            if (char < "A" || char > "Z") {
                continue;
            }
            total += 1;
            if (VOWELS.has(char)) {
                vowels += 1;
            }
        }
    });
    if (total === 0) {
        return 0;
    }
    return Number((vowels / total).toFixed(4));
}

function enrichLevel(seed) {
    const source = seed.source.map((word) => normalizeWord(word));
    const answers = seed.answers.map((word) => normalizeWord(word));
    const diffs = letterCountDiffs(source, answers);
    if (diffs.length > 0) {
        throw new Error(`${seed.ID}: source/answer letter mismatch (${diffs.join("; ")})`);
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
        NOTE: ""
    };
}

function loadLevelsNeedsCorrection() {
    if (!fs.existsSync(levelsNeedsCorrectionPath)) {
        return [];
    }

    const reviewSource = fs.readFileSync(levelsNeedsCorrectionPath, "utf8");
    const normalizedSource = reviewSource.replace(
        /^\s*export\s+const\s+levelsNeedsCorrection\s*=\s*/,
        "levelsNeedsCorrection = "
    );
    const context = { levelsNeedsCorrection: [] };
    vm.createContext(context);
    vm.runInContext(normalizedSource, context, { filename: levelsNeedsCorrectionPath });
    if (!Array.isArray(context.levelsNeedsCorrection)) {
        throw new Error("levels_needs_correction.js did not produce a levelsNeedsCorrection array.");
    }
    return context.levelsNeedsCorrection;
}

function main() {
    const levelDocument = loadLevelsDocument();
    const existingLevels = levelDocument.levels;
    const reviewLevels = loadLevelsNeedsCorrection();
    const existingIds = new Set(existingLevels.map((level, index) => getLevelId(level, index)));
    const reviewIds = new Set(reviewLevels.map((level, index) => getLevelId(level, index)));

    const seenNewIds = new Set();
    const prepared = [];
    const movedForCorrection = [];

    NEW_LEVELS.forEach((seed) => {
        if (existingIds.has(seed.ID)) {
            throw new Error(`Duplicate level ID already exists in levels.json: ${seed.ID}`);
        }
        if (reviewIds.has(seed.ID)) {
            throw new Error(`Duplicate level ID already exists in levels_needs_correction.js: ${seed.ID}`);
        }
        if (seenNewIds.has(seed.ID)) {
            throw new Error(`Duplicate level ID in new batch: ${seed.ID}`);
        }
        seenNewIds.add(seed.ID);

        try {
            prepared.push(enrichLevel(seed));
        } catch (error) {
            movedForCorrection.push({
                ID: seed.ID,
                source: seed.source.map((word) => normalizeWord(word)),
                answers: seed.answers.map((word) => normalizeWord(word)),
                CORRECTION_NOTE: `AUTO_MOVED_FOR_CORRECTION: ${error.message}`
            });
        }
    });

    if (prepared.length > 0) {
        const updatedLevels = [...existingLevels, ...prepared];
        saveLevelsDocument(updatedLevels, levelDocument.version);
    }

    if (movedForCorrection.length > 0) {
        const updatedReviewLevels = [...reviewLevels, ...movedForCorrection];
        fs.writeFileSync(levelsNeedsCorrectionPath, formatLevelsNeedsCorrection(updatedReviewLevels));
    }

    console.log(`Appended ${prepared.length} levels to public/levels.json.`);
    console.log(`Moved ${movedForCorrection.length} level(s) to ${path.relative(projectRoot, levelsNeedsCorrectionPath)}.`);
}

main();
