#!/usr/bin/env python3
"""Two mt76 questions, two caches: each script must say which one it read.

``check-mt76-pin.sh`` reads the fork mirror cache (``mt76-upstream.git``,
ref ``main``) and answers "is the pin far from the branch we clone, in
commits".  ``mt76-pin-age.py`` reads the openwrt/mt76 cache
(``mt76-openwrt.git``, ref ``master``) and answers "how much upstream time
has piled up".  Both are correct; run side by side on the real tree they
print ``keep`` and ``backlog``.  Without the cache identity next to the
verdict, that reads as a contradiction.

This case builds both caches at genuinely different tips and asserts that
each verdict carries its own repo path, ref and origin, so the two outputs
can never be mistaken for each other.

Run from the repository root:

    python3 -m unittest scripts.tests.test_mt76_pin_provenance

Red half: the age reader dates the tip with ``%cs``, the *committer* date, so
a fixture that sets only the author date is dated at the run's wall clock and
this test turns into "stale" once the pin is more than the fresh window old.
Put that bug back on a copy of this file (``commit()`` without
``GIT_COMMITTER_DATE``) and date the pin in the past, which is what every run
after 2026-11-28 looks like:

    $ cp scripts/tests/test_mt76_pin_provenance.py /tmp/prov_old.py
    # in /tmp/prov_old.py: drop GIT_COMMITTER_DATE from commit()'s env and
    # call build(pin_date="2026-09-01") in the first test
    $ python3 -m unittest -v /tmp/prov_old.py
    ...
    AssertionError: 'stale' != 'backlog'

This file fixes both dates and puts the 60 backlog commits on the pin's day
("young by date, heavy by commits"), so the verdict no longer sees the clock.
test_verdicts_do_not_depend_on_the_run_date runs the same assertions with a
pin dated 2026-09-01 and passes on any day.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CHECK = REPO_ROOT / "scripts/check-mt76-pin.sh"
AGE = REPO_ROOT / "scripts/mt76-pin-age.py"

PIN_TEMPLATE = """PKG_SOURCE_URL:=https://github.com/OpenWRT-fanboy/mt76-firmware
PKG_SOURCE_PROTO:=git
PKG_SOURCE_DATE:={pin_date}
PKG_SOURCE_VERSION:={pin_sha}
"""


def rows(stdout):
    out = {}
    for line in stdout.splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            out[key.strip()] = value.strip()
    return out


def keyed_rows(stdout):
    """`key value` rows (check-mt76-pin.sh) -> {key: value}."""
    out = {}
    for line in stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            out[parts[0]] = parts[1].strip()
    return out


class TwoCaches(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        home = self.root / "home"
        home.mkdir()
        self.env = dict(
            os.environ,
            HOME=str(home),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_TERMINAL_PROMPT="0",
            GIT_AUTHOR_NAME="t",
            GIT_AUTHOR_EMAIL="t@t",
            GIT_COMMITTER_NAME="t",
            GIT_COMMITTER_EMAIL="t@t",
        )

    def git(self, *args, cwd=None, env=None):
        return subprocess.run(["git"] + list(args), cwd=str(cwd or self.root),
                              env=env or self.env, capture_output=True, text=True,
                              check=True).stdout.strip()

    def commit(self, repo, message, when):
        # Both dates, not only the author date: mt76-pin-age.py reads %cs, so
        # --date alone dates the tip at the run's wall clock and this test
        # rots into "stale" one fresh-window after the pin.
        stamp = "%sT00:00:00+0000" % when
        self.git("-C", str(repo), "commit", "-q", "--allow-empty", "-m", message,
                 "--date", stamp, cwd=self.root,
                 env=dict(self.env, GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp))
        return self.git("-C", str(repo), "rev-parse", "HEAD")

    def build(self, pin_date="2026-10-28"):
        """One history, two caches: main frozen at the pin, master 60 ahead."""
        src = self.root / "src"
        self.git("init", "-q", "-b", "master", str(src))
        pin_sha = self.commit(src, "pin", pin_date)
        for i in range(60):
            # The pin's own day: the backlog band is "young by date, heavy by
            # commits", so a 60-day span would land in "stale" instead, and
            # 60 commits on 60 days cannot be backlog at all once the
            # committer dates are fixed.
            self.commit(src, "up %d" % i, pin_date)
        tip = self.git("-C", str(src), "rev-parse", "HEAD")
        self.git("-C", str(src), "branch", "frozen", pin_sha)

        # cache A: the fork mirror, ref main, still on the pin
        cache_a = self.root / "mt76-upstream.git"
        self.git("clone", "-q", "--bare", str(src), str(cache_a))
        self.git("-C", str(cache_a), "update-ref", "refs/heads/main", pin_sha)
        self.git("-C", str(cache_a), "update-ref", "-d", "refs/heads/master")
        self.git("-C", str(cache_a), "update-ref", "-d", "refs/heads/frozen")
        self.git("-C", str(cache_a), "remote", "set-url", "origin",
                 "https://example.invalid/mt76-firmware.git")

        # cache B: the openwrt/mt76 reader, ref master, 60 commits ahead
        cache_b = self.root / "mt76-openwrt.git"
        self.git("clone", "-q", "--bare", str(src), str(cache_b))
        self.git("-C", str(cache_b), "update-ref", "refs/heads/master", tip)
        self.git("-C", str(cache_b), "remote", "set-url", "origin",
                 "https://example.invalid/mt76.git")

        pin = self.root / "Makefile"
        pin.write_text(PIN_TEMPLATE.format(pin_date=pin_date, pin_sha=pin_sha),
                       encoding="utf-8")
        return pin, cache_a, cache_b

    def test_each_verdict_names_its_own_cache_and_ref(self):
        self.check_two_caches("2026-10-28")

    def test_verdicts_do_not_depend_on_the_run_date(self):
        # A pin dated well before today would read "stale" if anything here
        # consulted the wall clock; both verdicts must be the same as for a
        # pin dated yesterday.
        self.check_two_caches("2026-09-01")

    def check_two_caches(self, pin_date):
        pin, cache_a, cache_b = self.build(pin_date)

        check = subprocess.run(
            ["sh", str(CHECK), "--offline", "--pin-file", str(pin),
             "--patch-dir", str(self.root / "no-patches"),
             "--repo", str(cache_a), "--ref", "main"],
            env=self.env, capture_output=True, text=True, timeout=120)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        a = keyed_rows(check.stdout)
        self.assertEqual(a["verdict"], "keep")
        self.assertEqual(a["cache.repo"], str(cache_a))
        self.assertEqual(a["cache.ref"], "main")
        self.assertEqual(a["cache.origin"], "https://example.invalid/mt76-firmware.git")

        age = subprocess.run(
            [sys.executable, str(AGE), "--offline", "--pin-file", str(pin),
             "--repo", str(cache_b), "--ref", "master"],
            env=self.env, capture_output=True, text=True, timeout=120)
        self.assertEqual(age.returncode, 0, age.stdout + age.stderr)
        b = rows(age.stdout)
        self.assertEqual(b["verdict"], "backlog")
        self.assertEqual(b["commits_behind"], "60")
        self.assertEqual(b["cache.repo"], str(cache_b))
        self.assertEqual(b["cache.ref"], "master")
        self.assertEqual(b["cache.origin"], "https://example.invalid/mt76.git")

        # The two verdicts differ because the two readers differ; both say so.
        self.assertNotEqual(a["verdict"], b["verdict"])
        self.assertNotEqual(a["cache.repo"], b["cache.repo"])
        for label, rowset in (("check", a), ("age", b)):
            self.assertRegex(rowset["cache.fetched"], r"^\d{4}-\d{2}-\d{2}$", label)
            self.assertRegex(rowset["cache.age.days"], r"^\d+$", label)


if __name__ == "__main__":
    unittest.main(verbosity=2)
