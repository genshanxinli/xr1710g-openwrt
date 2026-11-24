#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Refuse a test cleanup that deletes a path parsed out of the script under test.

On 2026-11-21 a test printed a record path, parsed it back out of the program
under test, and cleaned up with ``shutil.rmtree(record.parent)``.  Fed a
broken copy of that script - one that printed ``/tmp/result.json`` instead of
a per-run directory - the parsed "record directory" was ``/``, the cleanup
called ``shutil.rmtree("/")``, and 100+ GB of build tree outside this
repository were gone.  No backup.

``scripts/tests/_cleanup.py`` (``safe_rmtree``) and
``scripts/tests/test_record_paths_absolute.py`` (``add_run_dir_cleanup``) fix
the call sites that exist today.  They do nothing about the next one somebody
writes, and a human audit of twenty ``rmtree`` call sites is a one-off.  This
is the standing gate for that pattern; it parses the tests with ``ast`` so a
docstring that mentions ``shutil.rmtree`` is not a call.

For every ``*.rmtree(...)`` call (and every ``addCleanup(X.rmtree, arg)``) in
``scripts/tests/**.py``, the first path argument must be one of:

  * ``tempfile.mkdtemp(...)``, directly or through a variable assigned from it
    anywhere in the same file;
  * a variable whose name says the test made it: ``tmp``, ``tmpdir``,
    ``sandbox``, ``work``, ``workdir``, ``scratch``, ``staging``;
  * the guarded path inside ``safe_rmtree`` itself (it resolves, then checks
    the scratch root and the run-directory name before deleting);
  * anything carrying ``# noqa: cleanup-safety <reason>`` on the call, with a
    reason - an unnamed exception is how the accident got written.

It is a violation when the argument

  * indexes ``.parents[N]`` - the exact shape of the accident, since the
    "record directory" of a shallow path is ``/``;
  * names something that came out of the program under test: ``record``,
    ``result``, ``parsed``, ``printed``, ``stdout``, ``stderr``, ``output``,
    ``reply`` in the attribute chain or the variable name - at any depth, so
    ``rmtree(str(parsed_dir))`` and ``addCleanup(rmtree, os.fspath(out), True)``
    are violations and not "unknown".  Wrapping a path in ``str()`` or
    ``os.fspath()`` does not make it the test's own.

An unrecognised name is *not* a violation: the gate cannot know whether it is
yours or the program's, and a gate that fails on every name it has not seen
gets an allowlist and then gets ignored.  Unknown sites are printed instead,
one line each, and the human decides.  There is no allowlist file: the rules
are here.  A call-wrapped argument the gate cannot resolve (anything other
than the rules above) is unknown as well, and says so in its message.

``--strict-unknown`` turns those unknowns into failures, for a caller that
wants the decision made now rather than at review time.

Usage::

    scripts/check-test-cleanup-safety.py                 # scripts/tests/**.py
    scripts/check-test-cleanup-safety.py PATH [PATH ...]  # files or directories
    scripts/check-test-cleanup-safety.py --strict-unknown  # unknowns fail too

Exit codes: 0 clean, 1 at least one violation (or an unknown under
``--strict-unknown``), 2 usage/input error.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path("scripts/tests")

NOQA = "noqa: cleanup-safety"
MIN_REASON = 8

# A test names the directory it created; a path out of the program under test
# never lands on one of these.
OWN_NAMES = frozenset(
    {"tmp", "tmpdir", "tmp_dir", "sandbox", "work", "workdir", "scratch", "staging"}
)

# Fragments that say "this value came out of the program under test".
UNTRUSTED = (
    "record",
    "result",
    "parsed",
    "printed",
    "stdout",
    "stderr",
    "output",
    "reply",
)

# The two helpers that check a path before deleting it; their own rmtree is
# the guarded one.
GUARD_FUNCTIONS = ("safe_rmtree", "add_run_dir_cleanup")

REASON_PREFIX = re.compile(r"^[\s:(\-]+")


def dotted(node: ast.AST) -> str:
    """``self.record.parent`` -> ``'self.record.parent'``; ``''`` otherwise."""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        base = dotted(node.value)
        return f"{base}.{node.attr}" if base else node.attr
    return ""


def calls_name(node: ast.AST, attr: str) -> bool:
    return (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == attr
    )


def is_mkdtemp(node: ast.AST) -> bool:
    return isinstance(node, ast.Call) and dotted(node.func).endswith("mkdtemp")


def has_mkdtemp(node: ast.AST) -> bool:
    return any(is_mkdtemp(sub) for sub in ast.walk(node))


def mkdtemp_names(tree: ast.AST) -> set[str]:
    """Names bound anywhere in the file to a ``tempfile.mkdtemp`` result."""
    names: set[str] = set()
    for node in ast.walk(tree):
        targets: list[ast.AST] = []
        value: ast.AST | None = None
        if isinstance(node, ast.Assign):
            targets, value = node.targets, node.value
        elif isinstance(node, ast.AnnAssign) and node.value is not None:
            targets, value = [node.target], node.value
        if value is None or not has_mkdtemp(value):
            continue
        for target in targets:
            chain = dotted(target)
            if chain:
                names.add(chain)
                names.add(chain.rsplit(".", 1)[-1])
    return names


def noqa_reason(lines: list[str], node: ast.AST) -> str | None:
    """The text after ``# noqa: cleanup-safety`` on the call, if present."""
    first = getattr(node, "lineno", 1)
    last = getattr(node, "end_lineno", first) or first
    for line in lines[first - 1 : last]:
        index = line.find(NOQA)
        if index < 0:
            continue
        return REASON_PREFIX.sub("", line[index + len(NOQA) :]).strip()
    return None


def indexes_parents(node: ast.AST) -> bool:
    """``x.parents[1]`` anywhere under ``node`` - the accident's shape."""
    for sub in ast.walk(node):
        if (
            isinstance(sub, ast.Subscript)
            and isinstance(sub.value, ast.Attribute)
            and sub.value.attr == "parents"
        ):
            return True
    return False


def chains(node: ast.AST) -> list[str]:
    """Every name/attribute chain under ``node``, in ``ast.walk`` order.

    ``ast.walk`` is breadth-first, so ``str(parsed_dir)`` yields
    ``['str', 'parsed_dir']``: the wrapper comes first, the name it wraps
    still comes.  That is the point - ``dotted()`` alone returned ``''`` for
    a Call and the argument escaped as "unknown" (the P0-4 gap).  The order
    only decides which chain the violation message quotes; every chain is
    graded, so the verdict is order-independent.
    """
    found: list[str] = []
    for sub in ast.walk(node):
        if isinstance(sub, (ast.Name, ast.Attribute)):
            chain = dotted(sub)
            if chain:
                found.append(chain)
    return found


def classify(
    arg: ast.AST | None,
    function: str | None,
    bound: set[str],
) -> tuple[str, str]:
    """('allow'|'violation'|'unknown', message)."""
    if arg is None:
        return "unknown", "no path argument"
    try:
        text = ast.unparse(arg)
    except Exception:  # pragma: no cover - unparse is total for parsed trees
        text = ast.dump(arg)

    if indexes_parents(arg):
        return (
            "violation",
            f"rmtree({text}) indexes .parents[N]; the record directory of a "
            "shallow path is / (the 2026-11-21 accident)",
        )

    # Grade the whole argument subtree, not just a bare dotted name: a
    # wrapper call (str(), os.fspath(), Path()) must not launder the value.
    under = chains(arg)
    for chain in under:
        lowered = chain.lower()
        for marker in UNTRUSTED:
            if marker in lowered:
                return (
                    "violation",
                    f"rmtree({text}) deletes a path that came out of the "
                    f"program under test ('{marker}' in '{chain}'); route it "
                    "through safe_rmtree or add_run_dir_cleanup",
                )

    if has_mkdtemp(arg):
        return "allow", ""
    if function in GUARD_FUNCTIONS:
        return "allow", ""

    for chain in under:
        parts = [part for part in chain.split(".") if part]
        if any(part in OWN_NAMES for part in parts):
            return "allow", ""
        if chain in bound or (parts and parts[-1] in bound):
            return "allow", ""

    if isinstance(arg, ast.Call):
        return (
            "unknown",
            f"rmtree({text}) wraps the path in a call; the gate cannot tell "
            "whose it is",
        )
    return "unknown", text


class Checker(ast.NodeVisitor):
    def __init__(self, path: Path, lines: list[str], bound: set[str]) -> None:
        self.path = path
        self.lines = lines
        self.bound = bound
        self.function: list[str] = []
        self.violations: list[tuple[int, str]] = []
        self.unknowns: list[tuple[int, str]] = []

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self.function.append(node.name)
        self.generic_visit(node)
        self.function.pop()

    visit_AsyncFunctionDef = visit_FunctionDef

    def check(self, arg: ast.AST | None, call: ast.AST) -> None:
        reason = noqa_reason(self.lines, call)
        if reason is not None:
            if len(reason) >= MIN_REASON:
                return
            self.violations.append(
                (
                    getattr(call, "lineno", 1),
                    f"{NOQA} needs a reason after it ('{reason}')",
                )
            )
            return
        verdict, message = classify(
            arg, self.function[-1] if self.function else None, self.bound
        )
        line = getattr(arg if arg is not None else call, "lineno", 1)
        if verdict == "violation":
            self.violations.append((line, message))
        elif verdict == "unknown":
            self.unknowns.append((line, message))

    def visit_Call(self, node: ast.Call) -> None:
        if (
            isinstance(node.func, ast.Attribute)
            and node.func.attr == "rmtree"
            and not isinstance(node.func.value, ast.Call)
        ):
            self.check(node.args[0] if node.args else None, node)
        elif (
            isinstance(node.func, ast.Attribute)
            and node.func.attr == "addCleanup"
            and node.args
            and isinstance(node.args[0], ast.Attribute)
            and node.args[0].attr == "rmtree"
        ):
            # addCleanup(shutil.rmtree, path, True) deletes exactly the same
            # thing, one indirection later.
            self.check(node.args[1] if len(node.args) > 1 else None, node)
        self.generic_visit(node)


def scan(path: Path) -> Checker:
    source = path.read_text(encoding="utf-8", errors="replace")
    tree = ast.parse(source, filename=str(path))
    checker = Checker(path, source.splitlines(), mkdtemp_names(tree))
    checker.visit(tree)
    return checker


def collect(arguments: list[str]) -> list[Path]:
    files: list[Path] = []
    for argument in arguments:
        path = Path(argument)
        if path.is_dir():
            files.extend(sorted(path.rglob("*.py")))
        elif path.is_file():
            files.append(path)
        else:
            raise SystemExit(f"{path}: no such file or directory")
    return files


def check(paths: list[Path], strict: bool = False) -> int:
    violations: list[tuple[Path, int, str]] = []
    unknowns: list[tuple[Path, int, str]] = []

    for path in paths:
        try:
            checker = scan(path)
        except (OSError, SyntaxError) as exc:
            line = getattr(exc, "lineno", 1) or 1
            violations.append((path, line, f"cannot parse: {exc}"))
            continue
        for line, message in checker.violations:
            violations.append((path, line, message))
        for line, message in checker.unknowns:
            unknowns.append((path, line, message))

    for path, line, message in violations:
        print(f"::error file={path},line={line}::{message}")
    for path, line, message in unknowns:
        if strict:
            print(f"::error file={path},line={line}::{message} (unknown under --strict-unknown)")
        else:
            print(
                f"unknown: {path}:{line}: {message} -- decide, or record why it is "
                f"ours with '# {NOQA} <reason>'"
            )
    verb = "FAILED" if violations or (strict and unknowns) else "OK"
    print(
        f"test cleanup safety: {verb}: {len(paths)} files, "
        f"{len(violations)} violations, {len(unknowns)} unknown"
    )
    return 1 if violations or (strict and unknowns) else 0


def main(argv: list[str]) -> int:
    strict = "--strict-unknown" in argv
    argv = [argument for argument in argv if argument != "--strict-unknown"]
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    arguments = argv or [str(DEFAULT_ROOT)]
    paths = collect(arguments)
    if not paths:
        print(f"no python files under {', '.join(arguments)}", file=sys.stderr)
        return 2
    return check(paths, strict)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
