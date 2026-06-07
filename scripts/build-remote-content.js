#!/usr/bin/env node

const path = require('path');
const {
  levelsPath,
  loadLevelsDocument,
  loadScheduleEntries,
  writeFormattedJSON
} = require('./levels-json');

const projectRoot = path.resolve(__dirname, '..');
const publicDir = path.join(projectRoot, 'public');
const scheduleOutputPath = path.join(publicDir, 'daily_schedule.json');

function nextVersion(previousVersion) {
  const now = Math.floor(Date.now() / 1000);
  const baseline = Number.isInteger(previousVersion) ? previousVersion : 0;
  return Math.max(now, baseline + 1);
}

function readPreviousVersions() {
  let levelsVersion = 0;
  let scheduleVersion = 0;

  const levelDocument = loadLevelsDocument();
  levelsVersion = levelDocument.version;

  try {
    const payload = JSON.parse(require('fs').readFileSync(scheduleOutputPath, 'utf8'));
    if (payload && typeof payload === 'object' && Number.isInteger(payload.version)) scheduleVersion = payload.version;
  } catch (_) {}

  return { levelsVersion, scheduleVersion };
}

function main() {
  const levelsSource = loadLevelsDocument();
  const scheduleEntries = loadScheduleEntries();
  const levelIDs = new Set(levelsSource.levels.map((level) => String(level.ID || "").trim()).filter(Boolean));

  const seenDates = new Set();
  const seenLevelIDs = new Set();
  const filledDates = [];
  for (const entry of scheduleEntries) {
    const date = String(entry.date || "").trim();
    const levelID = String(entry.ID || "").trim();

    if (!date) {
      throw new Error("daily_schedule.json contains an entry with an empty date.");
    }
    if (seenDates.has(date)) {
      throw new Error(`daily_schedule.json has duplicate date: ${date}`);
    }
    seenDates.add(date);

    if (!levelID) continue;
    if (!levelIDs.has(levelID)) {
      throw new Error(`daily_schedule.json references missing level ID: ${levelID}`);
    }
    if (seenLevelIDs.has(levelID)) {
      throw new Error(`daily_schedule.json has duplicate level ID: ${levelID}`);
    }
    seenLevelIDs.add(levelID);
    filledDates.push(date);
  }

  if (filledDates.length > 1) {
    const filledDateSet = new Set(filledDates);
    const sorted = [...filledDateSet].sort();
    const first = sorted[0];
    const last = sorted[sorted.length - 1];

    const parseUTCDate = (yyyyMMdd) => {
      const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(yyyyMMdd);
      if (!match) return null;
      const year = Number(match[1]);
      const month = Number(match[2]);
      const day = Number(match[3]);
      const date = new Date(Date.UTC(year, month - 1, day));
      if (
        date.getUTCFullYear() !== year ||
        date.getUTCMonth() !== month - 1 ||
        date.getUTCDate() !== day
      ) {
        return null;
      }
      return date;
    };

    const formatUTCDate = (date) => {
      const yyyy = date.getUTCFullYear();
      const mm = String(date.getUTCMonth() + 1).padStart(2, "0");
      const dd = String(date.getUTCDate()).padStart(2, "0");
      return `${yyyy}-${mm}-${dd}`;
    };

    const firstDate = parseUTCDate(first);
    const lastDate = parseUTCDate(last);
    if (!firstDate || !lastDate) {
      throw new Error(`daily_schedule.json has invalid date format in filled slots (expected YYYY-MM-DD).`);
    }

    const missingFilledDates = [];
    const cursor = new Date(firstDate);
    while (cursor <= lastDate) {
      const yyyyMMdd = formatUTCDate(cursor);
      if (!filledDateSet.has(yyyyMMdd)) {
        missingFilledDates.push(yyyyMMdd);
      }
      cursor.setUTCDate(cursor.getUTCDate() + 1);
    }

    if (missingFilledDates.length > 0) {
      const preview = missingFilledDates.slice(0, 10).join(", ");
      const suffix = missingFilledDates.length > 10 ? ` ... (+${missingFilledDates.length - 10} more)` : "";
      throw new Error(
        `daily_schedule.json is missing filled dates between ${first} and ${last}: ${preview}${suffix}`
      );
    }
  }

  const previous = readPreviousVersions();

  const levelsVersion = nextVersion(Math.max(previous.levelsVersion, levelsSource.version));
  const scheduleVersion = nextVersion(previous.scheduleVersion);

  const levelsDocument = {
    version: levelsVersion,
    levels: levelsSource.levels
  };

  const scheduleDocument = {
    version: scheduleVersion,
    schedule: scheduleEntries
  };

  writeFormattedJSON(levelsPath, levelsDocument);
  writeFormattedJSON(scheduleOutputPath, scheduleDocument);

  console.log(`Wrote ${path.relative(projectRoot, levelsPath)} (version ${levelsVersion}, ${levelsSource.levels.length} levels).`);
  console.log(`Wrote ${path.relative(projectRoot, scheduleOutputPath)} (version ${scheduleVersion}, ${scheduleEntries.length} entries).`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
