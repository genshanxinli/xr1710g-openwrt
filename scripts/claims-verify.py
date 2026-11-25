#!/usr/bin/env python3
"""Verify the CONTENT of the XR1710G claim ledger (scripts/claims.yaml).

scripts/check-claims.py validates the bookkeeping: fields present, ids unique,
``file:line`` sources resolving.  It cannot tell a true claim from a stale one --
a row can say "supported" while the tree has moved on.  This script re-checks
the content itself, using only the standard library and no network.

Evidence classes (this is the policy; keep it same in check-claims.py --help):

  A config  a Kconfig symbol has an expected value in the shipped kernel
            config (``.config``, ``auto.conf`` or a merged target fragment).
            Cheap: seconds, no build.  Mismatch -> FAIL.
  B symbol  a symbol is present in a built artifact (vmlinux, .ko, .o).
            Needs an artifact; when the artifact does not exist -> SKIP
            (reported, not failed), because CI never finishes a full build.
  C text    a ``path:line`` exists and holds an exact substring (byte match,
            no regex, so a rewrite cannot accidentally turn a row green).
            Mismatch -> FAIL.  A cited path that no longer exists (e.g. the
            deleted ``docs/`` tree) fails here.
  D device  read a sysfs/debugfs/proc file over ssh and compare the value.
            No static substitute exists.  Never run in CI: use --skip device.
            Locally it SKIPs when the box is unreachable, never FAILs on that.

A row with ``status: supported`` must carry at least one hook -- a ``verify:``
assertion, or ``manual: true`` plus ``verified_at`` (a commit sha).  Rows with
no hook at all are rejected by check-claims.py, so "format green" can no longer
mean "content green".

``needs-reverify`` (warning today, not a failure): a row records
``verified_at``, a straight re-check has no hook, and a path the row cites
changed between that sha and HEAD.  The warning exists so a code change pulls a
human back to the row instead of letting it rot green.  It becomes a failure
when the ledger has been re-baselined once; until then a warning is the honest
report, and the reason lives in this docstring rather than in a commit message.

Assertion syntax (one assertion per ``verify:`` list item, all optional):

    verify:
      - "symbol: build_dir/**/airoha_eth.o airoha_qdma_tx_bql_add"
      - "kconfig: build_dir/**/linux-7.4-rc3/.config CONFIG_TRACEPOINTS=y"
      - "text: target/linux/airoha/patches-7.4/210-....patch:17 if (hash >= ...)"
      - "device: /sys/class/watchdog/watchdog0/min_timeout 28"

    symbol   PATH-GLOB SYMBOL          byte-match inside the matched artifact
    kconfig  PATH-GLOB KEY=VALUE       VALUE is y, m, n (n covers
                                       "# KEY is not set") or a plain value
    text     PATH[:LINE] SUBSTRING     SUBSTRING is the rest of the item
    device   PATH EXPECTED             EXPECTED is the rest of the item

Every ``source`` entry is also re-read: ``path:line`` must exist with at least
that many lines, a bare path must exist, a ``.json`` file must parse, and URLs
are SKIP (they need the network).

Usage:

    python3 scripts/claims-verify.py                    # everything
    python3 scripts/claims-verify.py --dry-run          # plan only, no I/O
    python3 scripts/claims-verify.py --strict           # exit 1 on any FAIL
    python3 scripts/claims-verify.py --skip source,device
    python3 scripts/claims-verify.py --device-host 192.168.1.1

--skip takes a comma-separated class list (source, text, kconfig, symbol,
device); repeat --skip to name more than one.  CI runs the static layer only
(``--skip device``): the device class needs the box, and this repository's CI
never gets a self-hosted runner.  symbol is not skipped there -- without a
build_dir each ``symbol:`` line SKIPs on its own (reported, never a failure),
and when a built artifact is present it is byte-compared and still FAILs.

Exit status: 0 when nothing failed (SKIPs are not failures) and also when
checks failed but --strict was not given, 1 on --strict with any FAIL, 2 on a
usage/parse error.  The summary line always carries verified/failed/skipped,
so a non-gating FAIL is still visible.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_LEDGER = HERE / "claims.yaml"
DEFAULT_ROOT = HERE.parent
DEFAULT_DEVICE_HOST = "192.168.1.1"

VERBS = ("symbol", "kconfig", "text", "device")
CLASSES = ("source", "text", "kconfig", "symbol", "device")
VERB_CLASS = {"symbol": "symbol", "kconfig": "kconfig", "text": "text", "device": "device"}
URL_RE = re.compile(r"^https?://[^\s/]+(?:/[^\s]*)?$")
FILE_LINE_RE = re.compile(r"^([^\s:][^:]*):(\d+)$")

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


def _load_checker():
    """Import check-claims.py (hyphen in the name, so not a plain import)."""
    path = HERE / "check-claims.py"
    spec = importlib.util.spec_from_file_location("check_claims", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _parse_assertion(item: str) -> tuple[str, str]:
    """Split one verify item into (verb, rest).  Accepts 'verb:' or 'verb'."""
    item = item.strip()
    if not item:
        raise ValueError("empty verify assertion")
    tokens = item.split(None, 1)
    verb = tokens[0].rstrip(":").lower()
    if verb not in VERBS:
        raise ValueError(f"unknown verify verb {verb!r} (allowed: {', '.join(VERBS)})")
    rest = tokens[1].strip() if len(tokens) > 1 else ""
    if not rest:
        raise ValueError(f"verify {verb}: needs arguments")
    return verb, rest


def _paths(root: Path, pattern: str) -> list[Path]:
    """Resolve a repo-relative path or glob (``**`` allowed) under root."""
    if any(ch in pattern for ch in "*?["):
        try:
            return sorted(p for p in root.glob(pattern) if p.is_file())
        except (OSError, ValueError):
            return []
    candidate = root / pattern
    return [candidate] if candidate.is_file() else []


def _kconfig_value(text: str, key: str) -> str | None:
    for line in text.splitlines():
        line = line.strip()
        if line == f"# {key} is not set":
            return "n"
        if line.startswith(f"{key}="):
            return line[len(key) + 1 :].strip()
    return None


def check_symbol(root: Path, rest: str) -> tuple[str, str]:
    path_glob, _, symbol = rest.partition(" ")
    if not symbol.strip():
        return FAIL, f"symbol: needs '<path-glob> <symbol>', got {rest!r}"
    symbol = symbol.strip().split()[0]
    matches = _paths(root, path_glob)
    if not matches:
        return SKIP, f"no artifact matched {path_glob}"
    needle = symbol.encode()
    found = [p for p in matches if needle in p.read_bytes()]
    if found:
        return PASS, f"{symbol} in {found[0].relative_to(root)}"
    return FAIL, f"{symbol} absent from {matches[0].relative_to(root)}"


def check_kconfig(root: Path, rest: str) -> tuple[str, str]:
    parts = rest.split()
    if len(parts) < 2 or "=" not in parts[1]:
        return FAIL, f"kconfig: needs '<path> KEY=VALUE', got {rest!r}"
    path_glob, spec = parts[0], parts[1]
    key, _, expect = spec.partition("=")
    matches = _paths(root, path_glob)
    if not matches:
        return SKIP, f"no config matched {path_glob}"
    for path in matches:
        try:
            wanted = _kconfig_value(path.read_text(encoding="utf-8", errors="replace"), key)
        except OSError as exc:
            return FAIL, f"{path.relative_to(root)}: unreadable: {exc}"
        if wanted != expect:
            shown = "unset" if wanted is None else wanted
            return FAIL, f"{path.relative_to(root)}: {key}={shown}, expected {expect}"
    return PASS, f"{key}={expect} in {matches[0].relative_to(root)}"


def check_text(root: Path, rest: str) -> tuple[str, str]:
    first, _, substring = rest.partition(" ")
    substring = substring.strip()
    if not substring:
        return FAIL, f"text: needs '<path[:line]> <substring>', got {rest!r}"
    match = FILE_LINE_RE.fullmatch(first)
    line_no = None
    if match:
        first, line_no = match.group(1), int(match.group(2))
    path = root / first
    if not path.is_file():
        return FAIL, f"path missing: {first}"
    try:
        data = path.read_bytes()
    except OSError as exc:
        return FAIL, f"{first}: unreadable: {exc}"
    if line_no is None:
        haystack = data
    else:
        lines = data.splitlines()
        if line_no < 1 or line_no > len(lines):
            return FAIL, f"{first}:{line_no} outside 1..{len(lines)}"
        haystack = lines[line_no - 1]
    if substring.encode() in haystack:
        where = first if line_no is None else f"{first}:{line_no}"
        return PASS, f"{where} contains {substring!r}"
    return FAIL, f"{first}{':' + str(line_no) if line_no else ''} lacks {substring!r}"


def check_device(root: Path, rest: str, host: str, timeout: int) -> tuple[str, str]:
    path, _, expect = rest.partition(" ")
    expect = expect.strip()
    if not expect:
        return FAIL, f"device: needs '<path> <expected>', got {rest!r}"
    command = ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={timeout}",
               f"root@{host}", "cat", shlex.quote(path.strip())]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout + 5)
    except (OSError, subprocess.SubprocessError) as exc:
        return SKIP, f"device {host} unreachable: {exc}"
    if result.returncode != 0:
        return SKIP, f"device {host}: cat {path.strip()} rc={result.returncode}"
    got = result.stdout.strip()
    if got == expect:
        return PASS, f"{path.strip()} = {expect}"
    return FAIL, f"{path.strip()} = {got[:40]!r}, expected {expect!r}"


def check_source(root: Path, value: str) -> tuple[str, str]:
    value = value.strip()
    if URL_RE.fullmatch(value):
        return SKIP, f"url needs network: {value}"
    match = FILE_LINE_RE.fullmatch(value)
    path_text, line_no = (match.group(1), int(match.group(2))) if match else (value, None)
    path = root / path_text
    if not path.is_file():
        return FAIL, f"path missing: {path_text}"
    if line_no is not None:
        total = len(path.read_bytes().splitlines())
        if line_no < 1 or line_no > total:
            return FAIL, f"{path_text}:{line_no} outside 1..{total}"
        return PASS, f"{path_text}:{line_no} resolves"
    if path.suffix == ".json":
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeError) as exc:
            return FAIL, f"{path_text}: not valid JSON: {exc}"
        return PASS, f"{path_text} parses as JSON"
    return PASS, f"{path_text} exists"


def evaluate(record: dict, root: Path, skip: set[str], host: str, timeout: int,
             dry: bool) -> tuple[str, str]:
    """Run every assertion of one claim; return (status, reason)."""
    claim_id = record.get("id", "<no id>")
    sources = record.get("source") or []
    items = record.get("verify") or []
    manual = record.get("manual") == "true" and record.get("verified_at")

    if not items and not manual:
        if record.get("status") == "supported":
            return FAIL, "supported but has no verify:/manual hook"
        return SKIP, f"{record.get('status', '?')} row, no machine-checkable assertion"

    results: list[tuple[str, str, str]] = []
    dry_note = ""
    if "source" not in skip:
        for value in sources:
            if dry:
                results.append(("source", "DRY", value))
                continue
            status, reason = check_source(root, value)
            results.append(("source", status, reason))

    for item in items:
        try:
            verb, rest = _parse_assertion(item)
        except ValueError as exc:
            results.append(("verify", FAIL, str(exc)))
            continue
        if VERB_CLASS[verb] in skip:
            results.append((verb, SKIP, f"class {VERB_CLASS[verb]} skipped"))
            continue
        if dry:
            results.append((verb, "DRY", rest))
            continue
        if verb == "symbol":
            status, reason = check_symbol(root, rest)
        elif verb == "kconfig":
            status, reason = check_kconfig(root, rest)
        elif verb == "text":
            status, reason = check_text(root, rest)
        else:
            status, reason = check_device(root, rest, host, timeout)
        results.append((verb, status, reason))

    if dry:
        return "DRY", "; ".join(f"{kind}:{what}" for kind, _, what in results)

    failed = [(kind, reason) for kind, status, reason in results if status == FAIL]
    passed = [1 for _, status, _ in results if status == PASS]
    if failed:
        return FAIL, "; ".join(f"{kind} {reason}" for kind, reason in failed)
    if not passed:
        skipped = [(kind, why) for kind, status, why in results if status == SKIP]
        return SKIP, "; ".join(f"{kind} {why}" for kind, why in skipped) or "nothing to check"
    tail = [why for kind, status, why in results if status == SKIP]
    reason = f"{len(passed)} check(s) passed"
    if tail:
        reason += f" ({len(tail)} skipped: {tail[0]})"
    return PASS, reason


def _cited_paths(record: dict) -> list[str]:
    paths = []
    for value in record.get("source") or []:
        value = value.strip()
        if URL_RE.fullmatch(value):
            continue
        match = FILE_LINE_RE.fullmatch(value)
        paths.append(match.group(1) if match else value)
    return paths


def _is_shallow_clone(root: Path) -> bool:
    try:
        result = subprocess.run(["git", "-C", str(root), "rev-parse", "--is-shallow-repository"],
                                capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0 and result.stdout.strip() == "true"


def needs_reverify(record: dict, root: Path, head: str | None) -> str | None:
    """Name the drift check's verdict -- including "cannot tell".

    ``None`` means "the check ran and found nothing moved".  When the check
    cannot run (URL-only evidence, a truncated history, a bad sha) the reason
    is returned instead, because a silent ``None`` there is the bug P1-8: the
    warning went quiet exactly where the ledger most needed it.
    """
    sha = record.get("verified_at")
    if not sha or record.get("verify"):
        return None
    target = head or "HEAD"
    paths = _cited_paths(record)
    if not paths:
        return (f"no in-tree source to diff {sha}..{target}: row cites URLs only, "
                "so drift cannot be detected mechanically")
    command = ["git", "-C", str(root), "diff", "--name-only", f"{sha}..{target}", "--"] + paths
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        return f"cannot compare {sha}..{target}: git did not run ({exc})"
    if result.returncode != 0:
        detail = (result.stderr.strip().splitlines() or ["git diff failed"])[0]
        if _is_shallow_clone(root):
            detail += " (shallow clone: fetch full history, e.g. actions/checkout fetch-depth: 0)"
        return f"cannot compare {sha}..{target}: {detail}"
    changed = [line for line in result.stdout.splitlines() if line.strip()]
    if not changed:
        return None
    return f"cited path(s) changed since {sha}: {', '.join(changed[:4])}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Re-check the content of scripts/claims.yaml, not just its shape.",
        epilog=(
            "Evidence classes and policy:\n"
            "  A config  kconfig symbol has the expected value -> FAIL on mismatch\n"
            "  B symbol  symbol present in a built artifact    -> FAIL, SKIP without one\n"
            "  C text    path:line exists, exact substring     -> FAIL on mismatch\n"
            "  D device  sysfs/debugfs value over ssh          -> skip in CI (--skip device)\n"
            "  supported rows without a verify:/manual hook    -> FAIL (check-claims.py too)\n"
            "  needs-reverify (verified_at..HEAD touched a cited path) is a WARNING:\n"
            "    the ledger has not been re-baselined yet, so a hard failure would flag\n"
            "    rows nobody has re-read.  It turns into a failure after that pass.\n"
            "CI runs the static layer only: --skip device.  symbol is not skipped:\n"
            "    without a build_dir each symbol: line SKIPs (reported, never a\n"
            "    failure); with an artifact it is byte-compared and FAILs on a\n"
            "    mismatch."
        ),
    )
    parser.add_argument("--ledger", type=Path, default=None, metavar="PATH",
                        help="ledger to verify (default: scripts/claims.yaml here)")
    parser.add_argument("--root", type=Path, default=None, metavar="PATH",
                        help="repository root for cited paths (default: this checkout)")
    parser.add_argument("--skip", action="append", default=[], metavar="CLASS[,CLASS]",
                        help=f"classes to skip, comma separated: {', '.join(CLASSES)}; "
                             "repeatable")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 when any claim FAILs (skips are not failures)")
    parser.add_argument("--dry-run", action="store_true",
                        help="list the plan per claim and execute nothing")
    parser.add_argument("--device-host", default=DEFAULT_DEVICE_HOST,
                        help=f"ssh host for device: assertions (default: {DEFAULT_DEVICE_HOST})")
    parser.add_argument("--device-timeout", type=int, default=8, metavar="S",
                        help="ssh connect timeout for device: assertions (default: 8)")
    args = parser.parse_args(argv)

    skip = {part.strip() for chunk in args.skip for part in chunk.split(",") if part.strip()}
    unknown = skip - set(CLASSES)
    if unknown:
        parser.error(f"unknown class(es) in --skip: {', '.join(sorted(unknown))}")

    root = (args.root or DEFAULT_ROOT).expanduser().resolve()
    ledger = (args.ledger or DEFAULT_LEDGER).expanduser()
    try:
        text = ledger.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"{ledger}: cannot read ledger: {exc}", file=sys.stderr)
        return 2

    checker = _load_checker()
    try:
        records = checker.parse_ledger(text)
    except checker.LedgerError as exc:
        print(f"{ledger}:{exc.line}: parse error: {exc.message}", file=sys.stderr)
        return 2

    head = None
    if not args.dry_run and "symbol" not in skip:
        try:
            head = subprocess.run(["git", "-C", str(root), "rev-parse", "--short", "HEAD"],
                                  capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            head = None

    verified = failed = skipped = 0
    warnings: list[str] = []
    exit_code = 0

    for record in records:
        claim_id = record.get("id", "<no id>")
        status, reason = evaluate(record, root, skip, args.device_host,
                                  args.device_timeout, args.dry_run)
        print(f"{claim_id} {status} {reason}")
        if args.dry_run:
            continue
        if status == PASS:
            verified += 1
        elif status == FAIL:
            failed += 1
            exit_code = 1
        else:
            skipped += 1
        warning = needs_reverify(record, root, head)
        if warning:
            warnings.append(f"{claim_id} needs-reverify: {warning}")

    for line in warnings:
        print(f"WARN {line}", file=sys.stderr)

    print(f"verified={verified} failed={failed} skipped={skipped}")
    if warnings:
        print(f"needs-reverify={len(warnings)} (warning, not a failure)")

    if args.dry_run:
        return 0
    # Without --strict a FAIL is printed and counted but does not gate: the
    # ledger still holds rows whose content moved (see the notes on those
    # rows), and the PR job reports them instead of blocking on them.
    if args.strict and failed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
