#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Diff the airoha ethernet driver of two applied kernel trees, layer by layer.

The 7.3 and 7.4 patch queues are maintained in parallel and "the queue
applies" says nothing about what the patches still contain.  A patch that is
re-anchored onto a relocated file can keep applying while its hunks no longer
add the code they were written for; a rewrite can drop a call site and leave
the struct member behind as dead storage.  Neither shows up in the queue
gate, and neither is visible in `nm` or `strings` on the built vmlinux when
the orphan is a struct member: dead members occupy no memory.

So compare the *applied source trees*, which is what ships.  Three layers:

  A  symbol      every function, struct member, module parameter, debugfs
                 file and file-scope object in drivers/net/ethernet/airoha/
                 of each tree, as a name set.  Reported as 7.3-only and
                 7.4-only.  A name only the 7.3 tree has is either a real
                 loss or a rename -- layer B tells which by showing the call
                 sites the 7.4 tree no longer has.

  B  call sites  for every symbol both trees should share, the number of
                 uses (word occurrences minus the declaration itself).  A
                 symbol whose uses drop to zero is declaration-only: it
                 compiles, it links, nothing calls it.

  C  constants   #define values.  The same label with a different value in
                 the two trees is the highest-severity class of all: both
                 sides compile and the wrong one quietly programs a
                 different register.

usage:
  check_parity_73_vs_74.py <tree-7.3> <tree-7.4> [--min-hits N]
                           [--dir SUBDIR] [--verbose]
  check_parity_73_vs_74.py --self-test

  <tree-7.3> <tree-7.4>  applied trees, i.e. the top directory that holds
                         drivers/.  build them with
                         scripts/tests/apply-queue-f0.sh --keep
  --min-hits N           uses a symbol needs to count as still wired up
                         (default 1, i.e. at least one use beyond the
                         declaration)
  --dir SUBDIR           driver directory relative to each tree
                         (default drivers/net/ethernet/airoha)
  --verbose              also print the symbols that are complete

Output: one line per layer, "<layer>: complete|missing:N|dead:N|divergent:N",
the offending names with the 7.3 line they were defined on, and for layer B
the 7.3 call sites the 7.4 tree lost.  Exit status 0 only when all three
layers are complete, 2 on a usage error.

Known limit: the layer B use count is a word-occurrence count per symbol
name, not a call-graph count, so two structs that share a member name hide
each other's dead members.  Layer A stays exact.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

DEFAULT_SUBDIR = "drivers/net/ethernet/airoha"

# Names on the left of "name(args) {" that are statements, not definitions.
CONTROL = {
    "if", "for", "while", "switch", "return", "sizeof", "do", "else",
    "case", "typeof", "defined",
}

RE_FUNC = re.compile(
    r"(?m)^(?!#)([A-Za-z_][^\n;{}]*?)\b([A-Za-z_]\w*)\s*\(([^{};]*)\)"
    r"\s*(?:__[a-z0-9_]+\s*)*\{"
)
RE_MACRO_SYM = re.compile(r"(?m)^\s*(DEFINE_[A-Z_]+)\s*\(\s*(\w+)\s*\)")
RE_PARAM = re.compile(r"module_param(?:_named|_string|_cb)?\s*\(\s*(\w+)")
RE_DEBUGFS = re.compile(r'debugfs_create_\w+\s*\(\s*"([^"]+)"')
RE_STRUCT = re.compile(r"(?m)^struct\s+(\w+)\s*\{")
RE_MEMBER = re.compile(r"([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)*(?::\s*\d+\s*)?;")
RE_STATIC_OBJ = re.compile(
    r"(?m)^static\s+(?:const\s+|__ro_after_init\s+)*"
    r"(?:struct\s+\w+|[a-z_]\w*)\s+\*?(\w+)\s*(?:\[[^\]]*\])?\s*="
)
RE_DEFINE = re.compile(r"(?m)^\s*#\s*define\s+(\w+)\s+(?!\\)(.+)$")


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def extract_symbols(path: Path) -> dict[str, list[int]]:
    """name -> lines it is declared on in this file."""
    text = path.read_text(errors="replace")
    found: dict[str, list[int]] = {}

    def add(name: str, offset: int) -> None:
        found.setdefault(name, []).append(line_of(text, offset))

    for m in RE_FUNC.finditer(text):
        if m.group(2) in CONTROL:
            continue
        # A definition starts at column 0 and so does the return type, but a
        # "}" or a "#" prefix on the same line means this is a body-less
        # construct we do not want to call a function.
        if m.group(1).strip().startswith(("*", "#")):
            continue
        add("fn:" + m.group(2), m.start(2))
    for m in RE_MACRO_SYM.finditer(text):
        add("macro:%s(%s)" % (m.group(1), m.group(2)), m.start(2))
    for m in RE_PARAM.finditer(text):
        add("param:" + m.group(1), m.start(1))
    for m in RE_DEBUGFS.finditer(text):
        add("debugfs:" + m.group(1), m.start(1))
    for m in RE_STATIC_OBJ.finditer(text):
        add("obj:" + m.group(1), m.start(1))
    for sm in RE_STRUCT.finditer(text):
        start, depth, i = sm.end(), 1, sm.end()
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        for mm in RE_MEMBER.finditer(text[start:i - 1]):
            add("member:%s.%s" % (sm.group(1), mm.group(1)),
                start + mm.start(1))
    return found


def bare(name: str) -> str:
    """member:struct.field -> field; everything else keeps its own name."""
    if name.startswith("member:"):
        return name.split(".", 1)[1]
    if name.startswith("macro:"):
        return name[name.index("(") + 1:-1]
    return name.split(":", 1)[1]


def extract_defines(path: Path) -> dict[str, tuple[int, str]]:
    out: dict[str, tuple[int, str]] = {}
    text = path.read_text(errors="replace")
    for m in RE_DEFINE.finditer(text):
        value = m.group(2)
        value = re.sub(r"/\*.*?\*/", "", value)          # strip trailing block comment
        value = re.sub(r"\s+", "", value)                 # whitespace is not value
        if not value:
            continue
        out.setdefault(m.group(1), (line_of(text, m.start()), value))
    return out


class Tree:
    def __init__(self, root: Path, subdir: str):
        self.root = root
        self.dir = root / subdir
        if not self.dir.is_dir():
            raise SystemExit("no %s under %s" % (subdir, root))
        self.files = sorted(list(self.dir.glob("*.[ch]")))
        if not self.files:
            raise SystemExit("no .c/.h in %s" % self.dir)
        self.text = "\n".join(p.read_text(errors="replace") for p in self.files)
        self.symbols: dict[str, list[tuple[str, int]]] = {}
        for p in self.files:
            for name, lines in extract_symbols(p).items():
                self.symbols.setdefault(name, []).extend(
                    (p.name, n) for n in lines)
        self.defines: dict[str, tuple[int, str]] = {}
        for p in self.files:
            for name, value in extract_defines(p).items():
                self.defines.setdefault(name, value)

    def _pattern(self, name: str) -> re.Pattern:
        # A debugfs entry only exists as the string handed to
        # debugfs_create_*(), so match the literal and not the C identifier:
        # "weights" must not be satisfied by an unrelated TWRR weights[].
        if name.startswith("debugfs:"):
            return re.compile(r'"%s"' % re.escape(bare(name)))
        return re.compile(r"\b%s\b" % re.escape(bare(name)))

    def uses(self, name: str) -> int:
        """Occurrences of the symbol, minus its own declarations.

        A debugfs entry is declared by the debugfs_create_*() call that
        registers it, so that call is the declaration *and* the only thing
        that can prove the entry exists: do not subtract it.
        """
        hits = len(self._pattern(name).findall(self.text))
        if name.startswith("debugfs:"):
            return hits
        return hits - len(self.symbols.get(name, []))

    def call_sites(self, name: str) -> list[str]:
        """file:line of every use of name, for the 7.3 side of a loss."""
        pattern = self._pattern(name)
        decl = (set() if name.startswith("debugfs:")
                else {line for _, line in self.symbols.get(name, [])})
        sites = []
        for p in self.files:
            for no, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
                if no in decl or not pattern.search(line):
                    continue
                sites.append("%s:%d: %s" % (p.name, no, line.strip()[:88]))
        return sites


def compare(old: Tree, new: Tree, min_hits: int, verbose: bool) -> int:
    rc = 0

    # --- A: symbol names -------------------------------------------------
    only_old = sorted(set(old.symbols) - set(new.symbols))
    only_new = sorted(set(new.symbols) - set(old.symbols))
    state = "complete" if not only_old else "missing:%d" % len(only_old)
    print("A symbols: %s  (%d in 7.3, %d in 7.4)"
          % (state, len(old.symbols), len(new.symbols)))
    for name in only_old:
        print("  - %-52s 7.3 %s" % (name, formatter(old.symbols[name])))
    for name in only_new:
        print("  + %-52s only in 7.4, %s"
              % (name, formatter(new.symbols[name])))
    if only_old:
        rc = 1

    # --- B: uses ---------------------------------------------------------
    dead = []
    for name in sorted(set(old.symbols)):
        if old.uses(name) < min_hits:
            continue
        got = new.uses(name) if name in new.symbols else 0
        if got < min_hits:
            dead.append((name, old.uses(name), got))
    state = "complete" if not dead else "dead:%d" % len(dead)
    print("B call sites: %s  (a symbol needs %d use%s)"
          % (state, min_hits, "" if min_hits == 1 else "s"))
    for name, used, got in dead:
        print("  ! %-52s 7.3 uses %-3d 7.4 uses %d"
              % (name, used, got))
        for site in old.call_sites(name)[:6]:
            print("      lost: %s" % site)
    if dead:
        rc = 1

    # --- C: constants ----------------------------------------------------
    divergent = []
    for name in sorted(set(old.defines) & set(new.defines)):
        if old.defines[name][1] != new.defines[name][1]:
            divergent.append(name)
    lost_const = sorted(set(old.defines) - set(new.defines))
    state = ("complete" if not divergent and not lost_const
             else "divergent:%d" % len(divergent))
    extra = "" if not lost_const else "  lost:%d" % len(lost_const)
    print("C constants: %s%s  (%d defines in 7.3, %d in 7.4)"
          % (state, extra, len(old.defines), len(new.defines)))
    for name in divergent:
        print("  ! %s" % name)
        print("      7.3 line %-5d %s" % old.defines[name])
        print("      7.4 line %-5d %s" % new.defines[name])
    for name in lost_const:
        line, value = old.defines[name]
        print("  - %s  7.3 line %d %s" % (name, line, value))
    if divergent or lost_const:
        rc = 1

    if verbose:
        alive = [n for n in sorted(set(old.symbols) & set(new.symbols))
                 if old.uses(n) >= min_hits and new.uses(n) >= min_hits]
        print("complete symbols: %d" % len(alive))
        for name in alive:
            print("  = %s" % name)

    return rc


def formatter(sites: list[tuple[str, int]]) -> str:
    return " ".join("%s:%d" % site for site in sites[:4])


def self_test() -> int:
    """Tiny fixture trees: each layer must fire, and a clean pair must pass."""
    good = """
struct thing {
\tint live;
\tint orphan;
};
static int helper(int x) { return x; }
static int caller(void) { return helper(1); }
#define LIMIT GENMASK(3, 0)
"""
    lossy = """
struct thing {
\tint live;
\tint orphan;
};
static int caller(void) { return 0; }
#define LIMIT GENMASK(4, 0)
"""
    with tempfile.TemporaryDirectory() as td:
        for tag, body in (("old", good), ("new", lossy)):
            d = Path(td) / tag / DEFAULT_SUBDIR
            d.mkdir(parents=True)
            (d / "x.c").write_text(body)
        old = Tree(Path(td) / "old", DEFAULT_SUBDIR)
        new = Tree(Path(td) / "new", DEFAULT_SUBDIR)

        assert "fn:helper" in old.symbols and "fn:helper" not in new.symbols
        assert old.uses("member:thing.orphan") == 0
        assert old.defines["LIMIT"][1] != new.defines["LIMIT"][1]

        print("--- fixture: the lossy pair, expect exit 1")
        rc = compare(old, new, 1, False)
        assert rc == 1, "lossy pair must fail"

        print("--- fixture: the same tree twice, expect exit 0")
        rc = compare(old, old, 1, False)
        assert rc == 0, "identical pair must pass"
    print("self-test OK")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.split("\n")[0])
    ap.add_argument("tree_73", nargs="?")
    ap.add_argument("tree_74", nargs="?")
    ap.add_argument("--min-hits", type=int, default=1)
    ap.add_argument("--dir", default=DEFAULT_SUBDIR)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.tree_73 or not args.tree_74:
        ap.print_usage(sys.stderr)
        return 2

    old = Tree(Path(args.tree_73), args.dir)
    new = Tree(Path(args.tree_74), args.dir)
    rc = compare(old, new, args.min_hits, args.verbose)
    print("PARITY %s" % ("ok" if rc == 0 else "FAILED"))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
