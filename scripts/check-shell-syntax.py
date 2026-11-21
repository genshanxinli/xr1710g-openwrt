#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Parse every shell script with the interpreter its own shebang names.

`sh -n` is not a syntax check for a bash script.  dash rejects `;&`,
`declare -A` and `arr=(...)` at parse time, so a repo-wide `sh -n` scan can
only be made green by whitelisting the bash scripts - and a whitelist hides
the next real error in the file it names.  The same holds in reverse: a
`#!/bin/sh` script that is really bash (a bash body behind a re-exec guard)
is a mislabelled file, and `sh -n` says so.

So dispatch on the shebang, per file:

  #!/usr/bin/env bash, #!/bin/bash   -> bash -n
  #!/bin/sh, #!/bin/dash, #!/bin/ash -> sh -n
  no shebang                         -> sh -n (sourced fragment convention)
  any other interpreter (ucode, ...) -> skipped, it is not a shell script

There is no allowlist and no `--skip FILE`.  A file that will not parse under
its own interpreter is a bug in that file, not a line to add here.

Usage::

    scripts/check-shell-syntax.py                 # every tracked *.sh
    scripts/check-shell-syntax.py a.sh b.sh       # just these

Exit codes: 0 all parsed, 1 at least one failed, 2 usage/input error.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

# Basenames that mean "this file is a shell script" and which parser to use.
BASH_SHELLS = ("bash",)
POSIX_SHELLS = ("sh", "dash", "ash")


def shebang_interpreter(path: Path) -> str | None:
    """Return 'bash', 'sh', or None (no shebang, or not a shell at all)."""
    try:
        with path.open("rb") as handle:
            first = handle.readline(200).decode("utf-8", "replace").strip()
    except OSError as exc:
        raise SystemExit(f"{path}: cannot read: {exc}")

    if not first.startswith("#!"):
        return None
    parts = first[2:].split()
    if not parts:
        return None
    base = Path(parts[0]).name
    if base == "env":
        args = [part for part in parts[1:] if not part.startswith("-")]
        if not args:
            return None
        base = Path(args[0]).name
    if base in BASH_SHELLS:
        return "bash"
    if base in POSIX_SHELLS:
        return "sh"
    return None


def is_shell_script(path: Path) -> bool:
    """True when the shebang names a shell, or there is no shebang at all."""
    try:
        with path.open("rb") as handle:
            first = handle.readline(200).decode("utf-8", "replace").strip()
    except OSError:
        return False
    return not first.startswith("#!")


def interpreter_for(path: Path) -> str | None:
    """'bash', 'sh', or None when the file is not a shell script we parse.

    A missing shebang is treated as POSIX sh: that is the convention for the
    sourced fragments under package/**. A file whose shebang names something
    else (ucode) is skipped rather than parsed with a shell it does not use.
    """
    kind = shebang_interpreter(path)
    if kind is not None:
        return kind
    return "sh" if is_shell_script(path) else None


def check(paths: list[Path]) -> int:
    failed: list[tuple[Path, str, str]] = []
    skipped: list[Path] = []
    checked = 0

    for path in paths:
        interpreter = interpreter_for(path)
        if interpreter is None:
            skipped.append(path)
            continue
        tool = shutil.which(interpreter)
        if tool is None:
            raise SystemExit(f"{interpreter}: not installed; cannot check {path}")
        result = subprocess.run(
            [tool, "-n", str(path)],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        checked += 1
        if result.returncode:
            message = (result.stderr.strip() or result.stdout.strip()).splitlines()
            failed.append((path, interpreter, message[0] if message else "exit %d" % result.returncode))

    for path, interpreter, message in failed:
        print(f"{path}: {interpreter} -n: {message}", file=sys.stderr)
    if skipped:
        print(
            "skipped (not a shell script): " + ", ".join(str(path) for path in skipped),
            file=sys.stderr,
        )
    verb = "FAILED" if failed else "OK"
    print(
        f"shell syntax: {verb}: {checked} parsed, {len(failed)} failed, {len(skipped)} skipped"
    )
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if argv:
        if argv[0] in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        paths = [Path(arg) for arg in argv]
        missing = [str(path) for path in paths if not path.is_file()]
        if missing:
            print("no such file: " + ", ".join(missing), file=sys.stderr)
            return 2
        return check(paths)

    if shutil.which("git") is None:
        print("git is required to list the tracked scripts", file=sys.stderr)
        return 2
    listed = subprocess.run(
        ["git", "ls-files", "-z", "*.sh"],
        capture_output=True,
        text=True,
        check=False,
    )
    if listed.returncode:
        print(f"git ls-files failed: {listed.stderr.strip()}", file=sys.stderr)
        return 2
    return check([Path(name) for name in listed.stdout.split("\0") if name])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
