#!/usr/bin/env python3
"""No file that ships in the image may call flock with a busybox-less option.

On the device /usr/bin/flock is ../../bin/busybox and

    flock --help
    Usage: flock [-sxun] FD | { FILE [-c] PROG ARGS }

so there is no -w, no -E, no -o and no long option at all.  A call written as
"flock -w 200 9" exits 1 on the board, and because every caller trips it with
"|| { logger ...; exit 0; }" the whole protected body is skipped while the
source still looks bounded.  That is issue #243: 52-wan-lro, 54-pppoe-flowtable,
50-bridge-hw-offload, 51-bridge-hw-offload and wan-masq were all written that
way and none of them ever took its lock on hardware.

Scanned: every regular text file under target/linux/*/*/base-files,
target/linux/*/*/files and package/ -- i.e. what the image installs.  Comments
are ignored (they talk about the defect on purpose).  scripts/ is not scanned:
it runs on the build host, where util-linux flock is the one that is installed.

Run: python3 scripts/tests/test_flock_busybox_compat.py
"""

import glob
import os
import re
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# "flock [-sxun] FD | { FILE [-c] PROG ARGS }" is the whole of busybox's usage.
BUSYBOX_SHORT_OPTS = set("sxun")
MAX_FILE_BYTES = 1 << 20


def image_roots():
    roots = glob.glob(os.path.join(REPO, "target/linux/*/*/base-files"))
    roots += glob.glob(os.path.join(REPO, "target/linux/*/*/files"))
    roots.append(os.path.join(REPO, "package"))
    return [r for r in roots if os.path.isdir(r)]


def read_text(path):
    """File contents, or None when it is not a small text file."""
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            return None
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    if b"\0" in raw[:2048]:
        return None
    return raw.decode("utf-8", "replace")


def code_lines(text):
    """(lineno, line) with comment-only and trailing-comment text removed."""
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        cut = re.search(r"\s#", line)
        if cut:
            line = line[: cut.start()]
        yield lineno, line


def unsupported_options(line):
    """Options on any flock invocation in `line` that busybox's flock lacks."""
    bad = []
    for match in re.finditer(r"\bflock\b(?P<rest>[^;|&]*)", line):
        for token in match.group("rest").split():
            if token in ("-", "--"):
                break
            if not token.startswith("-"):
                break  # FD or FILE: options are over
            if token.startswith("--"):
                bad.append(token)
                break
            letters = token[1:]
            if not letters or set(letters) - BUSYBOX_SHORT_OPTS:
                bad.append(token)
                break
    return bad


def scan():
    """violations as "path:line: flock <opt>  <- <source line>"."""
    violations = []
    for root in image_roots():
        for dirpath, _dirs, names in os.walk(root):
            for name in names:
                path = os.path.join(dirpath, name)
                text = read_text(path)
                if text is None:
                    continue
                rel = os.path.relpath(path, REPO)
                for lineno, line in code_lines(text):
                    bad = unsupported_options(line)
                    if bad:
                        violations.append(
                            f"{rel}:{lineno}: flock {bad[0]}  <- {line.strip()}"
                        )
    return violations


class ScannerItself(unittest.TestCase):
    """The detector has to see the defect, or a green run means nothing."""

    def test_catches_the_original_bug(self):
        self.assertEqual(unsupported_options("\tflock -w 200 9 || {"), ["-w"])

    def test_catches_other_util_linux_only_options(self):
        for line in (
            "flock --timeout 5 9",
            "flock -E 75 9",
            "flock -o 9",
            "flock -xnw 5 9",
        ):
            self.assertTrue(unsupported_options(line), line)

    def test_accepts_what_busybox_does_have(self):
        for line in (
            "flock -n 9 || exit 1",
            "while ! flock -n 9; do",
            "flock 9",
            "flock -sxu 1000",
            "flock /var/run/hostapd.lock ubus call network reload",
            "flock -n 9; then flock -u 9",
        ):
            self.assertEqual(unsupported_options(line), [], line)

    def test_ignores_comments(self):
        text = "# was flock -w 10 9\n\tflock -n 9   # not flock -w 1\n"
        found = [l for _n, l in code_lines(text) if unsupported_options(l)]
        self.assertEqual(found, [])


class ImageScripts(unittest.TestCase):
    def test_no_busybox_less_flock_option(self):
        violations = scan()
        self.assertEqual(
            violations,
            [],
            "these files run on the device, where flock has only [-sxun]:\n  "
            + "\n  ".join(violations),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
