#!/usr/bin/env python3

import collections
import json
import re
import subprocess
import sys
from pathlib import Path

VOWELS = set("AEIOUY")
SMART_QUOTES = {
    "\u2018": "'",
    "\u2019": "'",
    "\u201c": '"',
    "\u201d": '"',
}


def read_input() -> str:
    if len(sys.argv) > 1:
        return Path(sys.argv[1]).read_text(encoding="utf-8")

    if sys.stdin.isatty():
        print("Usage: python3 scripts/generate_perfect_split_criteria.py <levels.json>", file=sys.stderr)
        print("   or: cat levels.json | python3 scripts/generate_perfect_split_criteria.py", file=sys.stderr)
        raise SystemExit(1)

    return sys.stdin.read()


def normalize_quotes(raw_input: str) -> str:
    normalized = raw_input
    for source, target in SMART_QUOTES.items():
        normalized = normalized.replace(source, target)
    return normalized


def parse_with_node(raw_input: str) -> list[dict]:
    node_script = r"""
const fs = require("fs");
const vm = require("vm");

const raw = fs.readFileSync(0, "utf8").replace(/[\u2018\u2019]/g, "'").replace(/[\u201C\u201D]/g, '"').trim();
let source = raw;
if (source.startsWith("export const levels")) {
  source = source.replace(/^\s*export\s+const\s+levels\s*=\s*/, "levels = ");
} else if (source.startsWith("[") || source.startsWith("{")) {
  source = `levels = ${source}`;
}

const context = { levels: [] };
vm.createContext(context);
vm.runInContext(source, context, { timeout: 1000 });
const parsed = Array.isArray(context.levels) ? context.levels : [context.levels];
process.stdout.write(JSON.stringify(parsed));
"""
    completed = subprocess.run(
        ["node", "-e", node_script],
        input=raw_input,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        stderr = completed.stderr.strip() or "unknown parse error"
        raise ValueError(f"Unable to parse input as JSON or JS levels: {stderr}")
    parsed = json.loads(completed.stdout)
    return parsed if isinstance(parsed, list) else [parsed]


def normalize_levels(raw_input: str) -> list[dict]:
    normalized_input = normalize_quotes(raw_input).strip()
    if not normalized_input:
        raise ValueError("Input is empty.")

    try:
        parsed = json.loads(normalized_input)
        return parsed if isinstance(parsed, list) else [parsed]
    except json.JSONDecodeError:
        return parse_with_node(normalized_input)


def get_level_id(level: dict, level_index: int) -> str:
    level_id = level.get("ID") or level.get("id")
    if not isinstance(level_id, str) or not level_id.strip():
        raise ValueError(f"Level {level_index + 1} is missing a valid ID.")
    return level_id.strip()


def require_words(level: dict, level_index: int, key: str, pattern: re.Pattern[str]) -> list[str]:
    raw_words = level.get(key)
    if not isinstance(raw_words, list) or not raw_words:
        raise ValueError(f"Level {level_index + 1} ({get_level_id(level, level_index)}) is missing a non-empty {key} array.")

    words: list[str] = []
    for word_index, word in enumerate(raw_words):
        if not isinstance(word, str) or not word.strip():
            raise ValueError(
                f"Level {level_index + 1} ({get_level_id(level, level_index)}) {key}[{word_index}] must be a non-empty string."
            )
        normalized = word.strip().upper()
        if not pattern.fullmatch(normalized):
            raise ValueError(
                f"Level {level_index + 1} ({get_level_id(level, level_index)}) {key}[{word_index}] contains invalid characters: {word!r}"
            )
        words.append(normalized)
    return words


def count_letters(words: list[str], ignore_asterisks: bool = False) -> collections.Counter[str]:
    counter: collections.Counter[str] = collections.Counter()
    for word in words:
        for char in word:
            if char == "*" and ignore_asterisks:
                continue
            if "A" <= char <= "Z":
                counter[char] += 1
    return counter


def assert_source_target_match(level: dict, level_index: int, source_words: list[str], answers: list[str]) -> None:
    source_counts = count_letters(source_words)
    answer_counts = count_letters(answers, ignore_asterisks=True)
    all_letters = sorted(set(source_counts) | set(answer_counts))

    diffs: list[str] = []
    for letter in all_letters:
        source_count = source_counts.get(letter, 0)
        answer_count = answer_counts.get(letter, 0)
        if source_count != answer_count:
            diffs.append(f"{letter}: source={source_count}, target={answer_count}")

    if diffs:
        raise ValueError(
            f"Level {level_index + 1} ({get_level_id(level, level_index)}) source/answer letter mismatch: {'; '.join(diffs)}"
        )


def collect_gold_letters(level: dict, level_index: int) -> list[str]:
    answers = require_words(level, level_index, "answers", re.compile(r"^[A-Z*]+$"))

    gold_letters: list[str] = []

    for answer_index, answer in enumerate(answers):
        if not isinstance(answer, str) or not answer:
            raise ValueError(f"Level {level_index + 1} answer {answer_index + 1} must be a non-empty string.")

        for index in range(1, len(answer)):
            if answer[index] == "*" and "A" <= answer[index - 1] <= "Z":
                gold_letters.append(answer[index - 1])

    return gold_letters


def calculate_vowel_ratio(source_words: list[str]) -> float:
    total = 0
    vowels = 0
    for word in source_words:
        for char in word:
            if "A" <= char <= "Z":
                total += 1
                if char in VOWELS:
                    vowels += 1
    if total == 0:
        return 0.0
    return round(vowels / total, 4)


def enrich_level(level: dict, level_index: int) -> dict:
    level_id = get_level_id(level, level_index)
    source_words = require_words(level, level_index, "source", re.compile(r"^[A-Z]+$"))
    answers = require_words(level, level_index, "answers", re.compile(r"^[A-Z*]+$"))

    assert_source_target_match(level, level_index, source_words, answers)

    gold_word = "".join(collect_gold_letters(level, level_index))
    enriched = {
        **level,
        "ID": level_id,
        "SCHEDULED": bool(level.get("SCHEDULED", level.get("ACTIVE", True))),
        "SOURCE_WORD_COUNT": len(source_words),
        "SOURCE_WORD_LENGTHS": [len(word) for word in source_words],
        "TARGET_ROW_COUNT": len(answers),
        "TARGET_ROW_LENGTHS": [len(word.replace("*", "")) for word in answers],
        "source": source_words,
        "VOWEL_RATIO": calculate_vowel_ratio(source_words),
        "answers": answers,
        "GOLD_WORD": gold_word,
        "CRITERIA_REGULAR": "[ROWS COMPLETED]/[TOTAL ROWS] WORDS",
        "CRITERIA_PERFECT": f"GOLD TILES SPELL {gold_word} IN ORDER",
        "NOTE": str(level.get("NOTE", "")),
    }
    return enriched


def build_levels_with_criteria(levels: list[dict]) -> list[dict]:
    result: list[dict] = []
    seen_ids: set[str] = set()
    target_word_occurrences: dict[str, list[str]] = {}

    for level_index, level in enumerate(levels):
        if not isinstance(level, dict):
            raise ValueError(f"Level {level_index + 1} must be an object.")
        level_id = get_level_id(level, level_index)
        if level_id in seen_ids:
            raise ValueError(f"Duplicate ID found: {level_id}")
        seen_ids.add(level_id)
        enriched = enrich_level(level, level_index)
        result.append(enriched)

        for row_index, answer in enumerate(enriched["answers"]):
            normalized_target = answer.replace("*", "")
            if not normalized_target:
                continue
            location = f"{level_id}#{row_index + 1}"
            target_word_occurrences.setdefault(normalized_target, []).append(location)

    duplicates = {
        word: locations
        for word, locations in sorted(target_word_occurrences.items())
        if len(locations) > 1
    }
    if duplicates:
        detail = "; ".join(f"{word}: {', '.join(locations)}" for word, locations in duplicates.items())
        raise ValueError(f"Duplicate target words across levels (ignoring *): {detail}")

    return result


def main() -> None:
    raw_input = read_input()
    levels = normalize_levels(raw_input)
    result = build_levels_with_criteria(levels)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
