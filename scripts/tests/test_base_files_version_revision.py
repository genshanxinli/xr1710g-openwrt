#!/usr/bin/env python3
"""base-files package version must follow the revision's ahead count (issue #372).

The package version used to be ``$(PKG_RELEASE)~$(lastword ...)`` which drops the
``rNNNNN+N`` part of ``REVISION``, so the apk name (and
``$(STAGING_DIR)/base-files.version``) stayed constant while ``+N`` moved, apk
considered the package up to date, and the rootfs kept an old
``DISTRIB_REVISION``.

Every check here runs a real ``make`` (``val.VERSION``), not a text match:

    export TOPDIR=$PWD SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
    make -C package/base-files -s --no-print-directory -f <Makefile> val.VERSION

``BASE_FILES_MAKEFILE=/path/to/Makefile`` points the probe at another copy of
``package/base-files/Makefile`` (used for the red proof); the test suite then
asserts that ``make`` really read that copy, so a wrong injection name cannot
produce a false green.
"""

import os
import re
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PKG_DIR = REPO / "package" / "base-files"
MAKEFILE = Path(os.environ.get("BASE_FILES_MAKEFILE") or (PKG_DIR / "Makefile")).resolve()
APK = REPO / "staging_dir" / "host" / "bin" / "apk"
TIMEOUT = 120

VERSION_RE = re.compile(r"^(?P<release>[0-9]+)(?:\.(?P<ahead>[0-9]+))?~(?P<hash>[0-9a-z]+)$")


def git_epoch():
    try:
        out = subprocess.run(
            ["git", "log", "-1", "--format=%ct"],
            cwd=REPO, capture_output=True, text=True, timeout=30, check=False,
        )
        return out.stdout.strip() or "0"
    except (OSError, subprocess.SubprocessError):
        return os.environ.get("SOURCE_DATE_EPOCH", "0")


def make_env(revision):
    env = {k: v for k, v in os.environ.items()
           if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
    env["TOPDIR"] = str(REPO)
    env["SOURCE_DATE_EPOCH"] = git_epoch()
    env["REVISION"] = revision
    return env


class BaseFilesVersionTest(unittest.TestCase):
    def setUp(self):
        self.assertNotEqual(MAKEFILE.name, "", "empty BASE_FILES_MAKEFILE")
        self.assertTrue(MAKEFILE.is_file(), f"makefile under test missing: {MAKEFILE}")

    def make(self, revision, *args):
        """Run make against the makefile under test; return stdout (no trailing NL)."""
        cmd = ["make", "-C", str(PKG_DIR), "--no-print-directory",
               "-f", str(MAKEFILE), *args]
        proc = subprocess.run(
            cmd, env=make_env(revision), capture_output=True, text=True,
            timeout=TIMEOUT, check=False,
        )
        if proc.returncode != 0:
            self.fail(
                f"make {' '.join(args)} failed rc={proc.returncode} for REVISION={revision}\n"
                f"  makefile under test: {MAKEFILE}\n"
                f"  cmd: {' '.join(cmd)}\n"
                f"  stderr:\n{proc.stderr.strip()}"
            )
        return proc.stdout.strip()

    def version(self, revision):
        return self.make(revision, "-s", "val.VERSION")

    def parse(self, version, revision):
        m = VERSION_RE.match(version)
        self.assertIsNotNone(
            m, f"version {version!r} for REVISION={revision} is not "
               f"<release>[.<ahead>]~<hash> (makefile under test: {MAKEFILE})"
        )
        return m

    def ahead(self, revision):
        return int(self.parse(self.version(revision), revision).group("ahead") or 0)

    # -- the injection must be real ---------------------------------------

    def test_makefile_under_test_is_what_make_reads(self):
        """Prove the make run above read MAKEFILE (guards against a false green)."""
        cmd = ["make", "-C", str(PKG_DIR), "--no-print-directory",
               "-f", str(MAKEFILE), "-p", "-n", "val.VERSION"]
        proc = subprocess.run(
            cmd, env=make_env("r38247+8-280fd1aabd"), capture_output=True,
            text=True, timeout=TIMEOUT, check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr.strip())
        marker = f"# makefile (from '{MAKEFILE}'"
        self.assertIn(
            marker, proc.stdout,
            f"make did not read {MAKEFILE}; it reported:\n"
            + "\n".join(l for l in proc.stdout.splitlines()
                        if l.startswith("# makefile (from"))[:4000]
        )

    # -- issue #372 behaviour ---------------------------------------------

    def test_ahead_count_changes_version(self):
        """+N is part of the version: +1 and +8 must not collide (the bug: they did)."""
        rev1, rev8 = "r38247+1-280fd1aabd", "r38247+8-280fd1aabd"
        v1, v8 = self.version(rev1), self.version(rev8)
        self.assertNotEqual(
            v1, v8,
            f"REVISION {rev1} and {rev8} both give VERSION {v1!r}: the ahead "
            f"count is dropped, apk will keep the stale package (issue #372); "
            f"makefile under test: {MAKEFILE}",
        )
        self.assertLess(self.ahead(rev1), self.ahead(rev8), f"{v1} !< {v8}")

    def test_version_is_apk_safe(self):
        """After '~' apk accepts only [0-9a-z]; nothing else may survive."""
        revision = "r38247+8-280fd1aabd"
        version = self.version(revision)
        tail = version.split("~", 1)[1] if "~" in version else ""
        self.assertRegex(tail, r"^[0-9a-z]+$", f"bad apk version tail in {version!r}")
        for bad in "+r-_ ":
            self.assertNotIn(
                bad, version,
                f"{bad!r} is not valid in an apk version: {version!r} "
                f"(makefile under test: {MAKEFILE})",
            )

    def test_shallow_clone_revision_degrades(self):
        """r0-<hash> (depth-1 clone) keeps the plain <release>~<hash> shape."""
        revision = "r0-084047e"
        version = self.version(revision)
        parsed = self.parse(version, revision)
        self.assertIsNone(parsed.group("ahead"),
                          f"unexpected ahead component in {version!r}")
        self.assertEqual(parsed.group("hash"), "084047e", version)
        self.assertNotIn(".", parsed.group("release"), version)

    def test_apk_orders_versions(self):
        """The bumped version must sort after the previous one (upgrade direction)."""
        if not APK.is_file():
            self.skipTest(f"no apk binary at {APK}")
        small, big = self.version("r38247+1-280fd1aabd"), self.version("r38247+8-280fd1aabd")
        proc = subprocess.run(
            [str(APK), "version", "-t", small, big],
            capture_output=True, text=True, timeout=TIMEOUT, check=False,
        )
        self.assertEqual(proc.returncode, 0,
                         f"apk rejected {small!r} or {big!r}: {proc.stderr.strip()}")
        self.assertEqual(proc.stdout.strip(), "<",
                         f"expected {small} < {big}, apk said {proc.stdout.strip()!r}")

    # -- the two use sites must stay in sync -------------------------------

    def test_version_and_base_files_version_use_one_expression(self):
        """package/base-files/Makefile writes the same string to both places."""
        text = MAKEFILE.read_text(encoding="utf-8")
        inline = re.findall(r"\$\(PKG_RELEASE\)~\$\(lastword \$\(subst -, ,\$\(REVISION\)\)\)", text)
        self.assertEqual(inline, [],
                         f"{len(inline)} inline PKG_RELEASE~lastword(...REVISION) "
                         f"expression(s) left in {MAKEFILE}")
        version_site = re.search(r"^  VERSION:=\$\((\w+)\)$", text, re.M)
        self.assertIsNotNone(version_site, f"no 'VERSION:=$(VAR)' line in {MAKEFILE}")
        var = version_site.group(1)
        self.assertRegex(text, r"(?m)^" + re.escape(var) + r"[:+]?=",
                         f"{var} is used by VERSION but not defined in {MAKEFILE}")
        self.assertIn("$(REVISION)", text, f"no $(REVISION) in {MAKEFILE}")
        self.assertIn(
            f"echo $({var}) >$(STAGING_DIR)/base-files.version", text,
            f"$(STAGING_DIR)/base-files.version is not written from {var} "
            f"in {MAKEFILE}: the two use sites disagree",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
