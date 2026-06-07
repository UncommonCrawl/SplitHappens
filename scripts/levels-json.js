#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const projectRoot = path.resolve(__dirname, "..");
const levelsPath = path.join(projectRoot, "public", "levels.json");
const schedulePath = path.join(projectRoot, "public", "daily_schedule.json");

function readJSON(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function isPrimitive(value) {
  return value === null || ["string", "number", "boolean"].includes(typeof value);
}

function formatJSON(value, indentLevel = 0) {
  const indent = "  ".repeat(indentLevel);
  const nested = "  ".repeat(indentLevel + 1);

  if (Array.isArray(value)) {
    if (value.length === 0) return "[]";
    if (value.every(isPrimitive)) {
      return `[${value.map((item) => JSON.stringify(item)).join(",")}]`;
    }
    const lines = value.map((item) => `${nested}${formatJSON(item, indentLevel + 1)}`);
    return `[\n${lines.join(",\n")}\n${indent}]`;
  }

  if (value && typeof value === "object") {
    const entries = Object.entries(value);
    if (entries.length === 0) return "{}";
    const lines = entries.map(([key, item]) => `${nested}${JSON.stringify(key)}: ${formatJSON(item, indentLevel + 1)}`);
    return `{\n${lines.join(",\n")}\n${indent}}`;
  }

  return JSON.stringify(value);
}

function writeFormattedJSON(filePath, value) {
  fs.writeFileSync(filePath, `${formatJSON(value)}\n`);
}

function loadLevelsDocument() {
  if (!fs.existsSync(levelsPath)) {
    throw new Error("public/levels.json is missing.");
  }

  const parsed = readJSON(levelsPath);
  if (Array.isArray(parsed)) {
    return { version: 0, levels: parsed };
  }
  if (parsed && typeof parsed === "object" && Array.isArray(parsed.levels)) {
    return {
      version: Number.isInteger(parsed.version) ? parsed.version : 0,
      levels: parsed.levels
    };
  }
  throw new Error("public/levels.json must be an array or a versioned object with a levels array.");
}

function saveLevelsDocument(levels, version) {
  const current = loadLevelsDocument();
  const resolvedVersion = Number.isInteger(version) ? version : current.version;
  writeFormattedJSON(levelsPath, { version: resolvedVersion, levels });
}

function loadScheduleEntries() {
  if (!fs.existsSync(schedulePath)) {
    throw new Error("public/daily_schedule.json is missing.");
  }
  const parsed = readJSON(schedulePath);
  if (Array.isArray(parsed)) return parsed;
  if (parsed && typeof parsed === "object" && Array.isArray(parsed.schedule)) return parsed.schedule;
  throw new Error("public/daily_schedule.json must be an array or a versioned object with a schedule array.");
}

module.exports = {
  levelsPath,
  loadLevelsDocument,
  saveLevelsDocument,
  loadScheduleEntries,
  formatJSON,
  writeFormattedJSON
};
