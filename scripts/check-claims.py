#!/usr/bin/env python3
"""Machine-check the XR1710G hardware claim ledger (scripts/claims.yaml).

The ledger is an INDEX, not the evidence itself.  Each entry points at a
file:line in this tree or at a URL; that source has to be re-read before the
claim is reused.  This checker only enforces the bookkeeping:

  * every entry has the required fields and only the documented fields;
  * ``evidence`` and ``status`` use the allowed values;
  * every entry cites at least one source, and each ``file:line`` source
    resolves to an existing line in this checkout;
  * ids are unique;
  * an inference-only claim (``evidence: 推断``) is not promoted to
    ``status: supported``.

The ledger is deliberately kept to a small YAML subset so this checker runs
with the Python standard library on any build host (no PyYAML package):

    claims:
      - id: slug
        claim: "one-sentence claim"
        source:
          - path/in/tree:LINE
          - https://example.invalid/...
        evidence: 实测 | 代码 | 推断
        date: "YYYY-MM-DD"
        status: supported | refuted | unverified
        notes: "limitations, or why the status is what it is"

Only block mappings, block sequences, plain scalars and double-quoted
scalars are accepted.  Tabs, anchors, aliases, flow collections, multi-line
scalars and single-quoted scalars are rejected with a parse error naming the
line, so a malformed ledger never passes silently.

Exit status: 0 when the ledger is valid (and within the strict budget, when
requested), 1 on a validation or parse error, 2 on a usage error.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

FIELDS = ("id", "claim", "source", "evidence", "date", "status", "notes")
REQUIRED_FIELDS = ("id", "claim", "source", "evidence", "date", "status")
EVIDENCE_VALUES = ("实测", "代码", "推断")
STATUS_VALUES = ("supported", "refuted", "unverified")

ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
FIELD_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
URL_RE = re.compile(r"^https?://[^\s/]+(?:/[^\s]*)?$")
FILE_LINE_RE = re.compile(r"^([^\s:][^:]*):(\d+)$")


class LedgerError(Exception):
    """A parse error tied to one line of the ledger."""

    def __init__(self, line: int, message: str) -> None:
        super().__init__(message)
        self.line = line
        self.message = message


def _strip_comment(line: str) -> str:
    """Drop a YAML comment, ignoring '#' inside a double-quoted scalar."""
    in_quotes = False
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if in_quotes and char == "\\":
            escaped = True
            continue
        if char == '"':
            in_quotes = not in_quotes
            continue
        if not in_quotes and char == "#" and (index == 0 or line[index - 1].isspace()):
            return line[:index].rstrip()
    return line.rstrip()


def _parse_scalar(token: str, line: int) -> str:
    """Parse one plain or double-quoted scalar from the ledger subset."""
    token = token.strip()
    if not token:
        raise LedgerError(line, "empty value (use a double-quoted string)")
    if token.startswith('"'):
        if len(token) < 2 or not token.endswith('"'):
            raise LedgerError(line, "unterminated double-quoted scalar")
        try:
            value = json.loads(token)
        except ValueError as exc:
            raise LedgerError(line, f"invalid double-quoted scalar: {exc}") from None
        if not isinstance(value, str):
            raise LedgerError(line, "double-quoted scalar must decode to a string")
        return value
    if token.startswith("'"):
        raise LedgerError(line, "single-quoted scalars are not supported; use double quotes")
    if token[0] in "[{&*!|>%@`":
        raise LedgerError(
            line,
            f"unsupported YAML construct {token[0]!r}; use a plain or double-quoted scalar",
        )
    if ": " in token:
        raise LedgerError(line, "plain scalar contains ': '; wrap it in double quotes")
    return token


def _split_field(text: str, line: int) -> tuple[str, str]:
    key, separator, value = text.partition(":")
    if not separator:
        raise LedgerError(line, f"expected 'key: value', got {text!r}")
    key = key.strip()
    if not FIELD_NAME_RE.fullmatch(key):
        raise LedgerError(line, f"invalid field name {key!r}")
    return key, value.strip()


def _new_record(line: int) -> dict:
    return {
        "__line__": line,
        "__field_lines__": {},
        "__source_lines__": [],
    }


def _set_field(record: dict, key: str, value: str, line: int) -> None:
    if key not in FIELDS:
        raise LedgerError(line, f"unknown field {key!r} (allowed: {', '.join(FIELDS)})")
    if key in record["__field_lines__"]:
        raise LedgerError(line, f"duplicate field {key!r}")
    record["__field_lines__"][key] = line
    if key == "source":
        if value:
            raise LedgerError(line, "field 'source' must be a block list, one '- entry' per line")
        record["source"] = []
        record["__source_lines__"] = []
        return
    if not value:
        raise LedgerError(line, f"field {key!r} needs a value on the same line")
    record[key] = _parse_scalar(value, line)


def parse_ledger(text: str) -> list[dict]:
    """Parse the ledger subset into records, annotating lines for errors."""
    records: list[dict] = []
    current: dict | None = None
    in_source_list = False
    seen_claims = False

    for number, raw in enumerate(text.splitlines(), 1):
        if not raw.strip():
            continue
        if "\t" in raw:
            raise LedgerError(number, "tab characters are not allowed; use spaces")
        line = _strip_comment(raw)
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        content = line[indent:]

        if indent == 0:
            key, value = _split_field(content, number)
            if key != "claims":
                raise LedgerError(
                    number,
                    f"unexpected top-level key {key!r}; only 'claims:' is supported",
                )
            if seen_claims:
                raise LedgerError(number, "duplicate 'claims:' section")
            if value:
                raise LedgerError(number, "'claims:' must be followed by a block sequence")
            seen_claims = True
            current = None
            in_source_list = False
            continue

        if not seen_claims:
            raise LedgerError(number, "indented content before the 'claims:' key")

        if indent == 2:
            if content == "-":
                current = _new_record(number)
                records.append(current)
                in_source_list = False
                continue
            if not content.startswith("- "):
                raise LedgerError(number, f"expected a '- ' claim entry, got {content!r}")
            current = _new_record(number)
            records.append(current)
            in_source_list = False
            key, value = _split_field(content[2:], number)
            _set_field(current, key, value, number)
            in_source_list = key == "source"
            continue

        if indent == 4:
            if current is None:
                raise LedgerError(number, "field line outside a claim entry")
            key, value = _split_field(content, number)
            _set_field(current, key, value, number)
            in_source_list = key == "source" and value == ""
            continue

        if indent == 6:
            if current is None or not in_source_list:
                raise LedgerError(number, "source item without a 'source:' field")
            if not content.startswith("- "):
                raise LedgerError(number, f"expected a '- ' source item, got {content!r}")
            item = _parse_scalar(content[2:], number)
            current["source"].append(item)
            current["__source_lines__"].append(number)
            continue

        raise LedgerError(number, "unexpected indentation (expected 0, 2, 4 or 6 spaces)")

    if not seen_claims:
        raise LedgerError(1, "top-level 'claims:' key not found")
    if not records:
        raise LedgerError(1, "no claims found under 'claims:'")
    return records


def _check_source(value: str) -> str | None:
    """Return a problem description for one source entry, or None."""
    value = value.strip()
    if not value:
        return "empty source"
    if URL_RE.fullmatch(value):
        return None

    match = FILE_LINE_RE.fullmatch(value)
    if not match:
        return "not a URL and not a repo-relative 'path:line'"

    path_text, line_text = match.groups()
    try:
        path = Path(path_text)
        if path.is_absolute() or ".." in path.parts:
            return "file:line must stay inside the repository (no absolute path, no '..')"
        full = REPO_ROOT / path
        if not full.is_file():
            return f"file not found: {path_text}"
    except (OSError, ValueError) as exc:
        return f"invalid path {path_text!r}: {exc}"
    try:
        content = full.read_text(encoding="utf-8")
    except (OSError, UnicodeError, ValueError):
        return f"file is not readable UTF-8 text: {path_text}"
    total = len(content.splitlines())
    number = int(line_text)
    if number < 1 or number > total:
        return f"line {number} is outside {path_text} (valid range 1..{total})"
    return None


def validate(records: list[dict]) -> list[tuple[int, str | None, str]]:
    """Validate parsed records; return (line, claim id, message) problems."""
    problems: list[tuple[int, str | None, str]] = []
    known_ids: dict[str, int] = {}

    for record in records:
        start = record["__line__"]
        field_lines = record["__field_lines__"]
        claim_id = record.get("id") or None

        def add(field: str, message: str) -> None:
            line = field_lines.get(field, start)
            problems.append((line, claim_id, message))

        for field in REQUIRED_FIELDS:
            if field not in record:
                add(field, f"missing required field {field!r}")

        if "id" in record:
            value = record["id"]
            if not value.strip():
                add("id", "field 'id' must not be empty")
            elif not ID_RE.fullmatch(value):
                add("id", "field 'id' must be a lowercase slug (a-z, 0-9, '.', '_', '-')")
            elif value in known_ids:
                add("id", f"duplicate id {value!r} (first used on line {known_ids[value]})")
            else:
                known_ids[value] = field_lines["id"]

        if "claim" in record and not record["claim"].strip():
            add("claim", "field 'claim' must not be empty")

        if "source" in record:
            sources = record["source"]
            if not sources:
                add("source", "field 'source' needs at least one file:line or URL")
            for index, item in enumerate(sources):
                line = (
                    record["__source_lines__"][index]
                    if index < len(record["__source_lines__"])
                    else field_lines.get("source", start)
                )
                problem = _check_source(item)
                if problem:
                    problems.append((line, claim_id, f"source {item!r}: {problem}"))

        if "evidence" in record and record["evidence"] not in EVIDENCE_VALUES:
            add("evidence", f"field 'evidence' must be one of {', '.join(EVIDENCE_VALUES)}")

        if "date" in record:
            value = record["date"]
            if not DATE_RE.fullmatch(value):
                add("date", "field 'date' must be YYYY-MM-DD")
            else:
                try:
                    dt.date.fromisoformat(value)
                except ValueError:
                    add("date", f"field 'date' is not a valid calendar date: {value!r}")

        if "status" in record and record["status"] not in STATUS_VALUES:
            add("status", f"field 'status' must be one of {', '.join(STATUS_VALUES)}")

        if "notes" in record and not record["notes"].strip():
            add("notes", "field 'notes' must not be empty when present")

        if record.get("evidence") == "推断" and record.get("status") == "supported":
            add(
                "status",
                "an inference-only claim ('推断') cannot be 'supported'; "
                "cite 实测/代码 evidence or set status to 'unverified'",
            )

    return problems


def _display_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate scripts/claims.yaml (the XR1710G hardware claim ledger).",
    )
    parser.add_argument(
        "--ledger",
        type=Path,
        default=None,
        metavar="PATH",
        help="ledger to check (default: scripts/claims.yaml next to this script)",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="also fail when the number of unverified claims exceeds --max-unverified",
    )
    parser.add_argument(
        "--max-unverified",
        type=int,
        default=0,
        metavar="N",
        help="allowed number of unverified claims in strict mode (default: 0)",
    )
    args = parser.parse_args(argv)

    if args.max_unverified < 0:
        parser.error("--max-unverified must be >= 0")

    ledger = (args.ledger or Path(__file__).resolve().with_name("claims.yaml")).expanduser()
    display = _display_path(ledger)

    try:
        text = ledger.read_text(encoding="utf-8")
    except FileNotFoundError:
        print(f"{display}: ledger not found", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"{display}: cannot read ledger: {exc}", file=sys.stderr)
        return 1

    try:
        records = parse_ledger(text)
    except LedgerError as exc:
        print(f"{display}:{exc.line}: parse error: {exc.message}", file=sys.stderr)
        print(f"{display}: FAILED: 1 problem", file=sys.stderr)
        return 1

    problems = validate(records)
    if problems:
        for line, claim_id, message in problems:
            where = f"claim {claim_id!r}" if claim_id else "ledger"
            print(f"{display}:{line}: {where}: {message}", file=sys.stderr)
        print(f"{display}: FAILED: {len(problems)} problem(s)", file=sys.stderr)
        return 1

    counts = {status: 0 for status in STATUS_VALUES}
    for record in records:
        counts[record["status"]] += 1
    print(
        f"{display}: OK: {len(records)} claims "
        f"({counts['supported']} supported, {counts['refuted']} refuted, "
        f"{counts['unverified']} unverified)"
    )

    if args.strict:
        if counts["unverified"] > args.max_unverified:
            print(
                f"{display}: strict: {counts['unverified']} unverified claim(s) "
                f"exceed the budget of {args.max_unverified}",
                file=sys.stderr,
            )
            return 1
        print(
            f"{display}: strict: {counts['unverified']} unverified claim(s) "
            f"within the budget of {args.max_unverified}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
