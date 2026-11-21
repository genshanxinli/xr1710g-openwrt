#!/usr/bin/env python3
"""Offline regression cases for scripts/mt76-pin-age.py (#9).

The script answers one question -- "how many upstream days is the mt76 pin
behind?" -- and the answer is a verdict plus an exit status:

  fresh    age <= 30 and commits_behind < 50               exit 0
  backlog  age <= 30 and commits_behind >= 50              exit 0, plus
           `backlog-pin: N commits behind` on stderr
  stale    31 .. 90    exit 0, plus `stale-pin: N days behind` on stderr
  blocked  > 90, or an unreadable pin date / upstream tip   exit 2

Two injection paths, on purpose:

  * `MT76_PIN_AGE_UNDER_TEST="pin_date=... upstream_date=..."` fixes the two
    dates without touching the Makefile or git.  That is how the three verdict
    bands and the band edges are pinned, so a threshold edit cannot move them.
  * a throw-away git repository plus a throw-away pin file (MT76_PIN_FILE /
    MT76_PIN_AGE_REPO) exercises the real path: parse the Makefile, read the
    branch tip out of the cache, do the date math.  No network, no shared
    cache: every case builds its own repository.

The red proof is not a case here -- it is the same suite pointed at a mutated
copy via `MT76_PIN_AGE_SCRIPT_UNDER_TEST`, so a passing suite proves the cases
read the script and not a constant.

Run from the repository root:

    python3 -m unittest scripts.tests.test_mt76_pin_age
"""

import os
import subprocess
import sys
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(os.environ.get("MT76_PIN_AGE_SCRIPT_UNDER_TEST",
                             REPO_ROOT / "scripts/mt76-pin-age.py"))
WORKFLOW = REPO_ROOT / ".github/workflows/mt76-pin-age.yml"

PIN_TEMPLATE = """PKG_SOURCE_URL:=https://github.com/OpenWRT-fanboy/mt76-firmware
PKG_SOURCE_PROTO:=git
PKG_SOURCE_DATE:={pin_date}
PKG_SOURCE_VERSION:={pin_sha}
"""


def run(env=None, args=()):
    """(rc, stdout, stderr) of the script under test, with a clean environment."""
    child = os.environ.copy()
    for key in ("MT76_PIN_AGE_UNDER_TEST", "MT76_PIN_AGE_REPO", "MT76_PIN_AGE_REF",
                "MT76_PIN_AGE_URL", "MT76_PIN_FILE"):
        child.pop(key, None)
    child.update(env or {})
    done = subprocess.run([sys.executable, str(SCRIPT), *args],
                          capture_output=True, text=True, env=child, timeout=60)
    return done.returncode, done.stdout, done.stderr


def rows(stdout):
    """`key: value` rows -> {key: value}; the label keeps its own words."""
    out = {}
    for line in stdout.splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            out[key.strip()] = value.strip()
    return out


def inject(pin_date, upstream_date, pin_sha="abc1234567890",
           upstream_sha="def1234567890", commits_behind=None):
    spec = "pin_date=%s pin_sha=%s upstream_date=%s upstream_sha=%s" % (
        pin_date, pin_sha, upstream_date, upstream_sha)
    if commits_behind is not None:
        spec += " commits_behind=%s" % commits_behind
    return {"MT76_PIN_AGE_UNDER_TEST": spec}


class VerdictBandTest(unittest.TestCase):
    """The three bands, pinned by injected dates only."""

    def test_fresh_is_quiet(self):
        rc, out, err = run(inject("2026-11-01", "2026-11-10"))
        self.assertEqual(rc, 0)
        self.assertEqual(rows(out)["verdict"], "fresh")
        self.assertEqual(rows(out)["age"], "9 days")
        self.assertEqual(err, "", "a fresh verdict must not annotate anything")

    def test_stale_warns_on_stderr_and_still_exits_zero(self):
        rc, out, err = run(inject("2026-10-01", "2026-11-20"))
        self.assertEqual(rc, 0, "stale is a warning, not a failed job")
        self.assertEqual(rows(out)["verdict"], "stale")
        self.assertEqual(rows(out)["age"], "50 days")
        self.assertEqual(err.strip(), "stale-pin: 50 days behind")

    def test_blocked_over_ninety_days_exits_two(self):
        rc, out, err = run(inject("2026-08-01", "2026-11-20"))
        self.assertEqual(rc, 2)
        self.assertEqual(rows(out)["verdict"], "blocked")
        self.assertIn("> 90", rows(out)["reason"])

    def test_blocked_without_an_upstream_tip(self):
        rc, out, err = run({"MT76_PIN_AGE_UNDER_TEST":
                            "pin_date=2026-10-28 pin_sha=46b67e5b upstream_date="})
        self.assertEqual(rc, 2)
        self.assertEqual(rows(out)["verdict"], "blocked")
        self.assertEqual(rows(out)["age"], "unknown")
        self.assertEqual(rows(out)["upstream master"], "unavailable")

    def test_band_edges(self):
        # 30 -> fresh, 31 -> stale, 90 -> stale, 91 -> blocked.  A threshold
        # edit that moves any edge turns exactly one of these red.
        for days, verdict, rc in ((30, "fresh", 0), (31, "stale", 0),
                                  (90, "stale", 0), (91, "blocked", 2)):
            pin = date(2026, 1, 1)
            upstream = pin + timedelta(days=days)
            got_rc, out, err = run(inject(pin.isoformat(), upstream.isoformat()))
            self.assertEqual(got_rc, rc, "age %d: rc" % days)
            self.assertEqual(rows(out)["verdict"], verdict, "age %d: verdict" % days)
            self.assertEqual(rows(out)["age"], "%d days" % days, "age %d: row" % days)

    def test_age_does_not_consult_the_wall_clock(self):
        # "today minus the pin" would make a quiet upstream look stale as the
        # pin ages.  The metric is upstream_tip - pin, so this stays fresh no
        # matter when the suite runs.
        rc, out, _ = run(inject("2026-01-01", "2026-01-05"))
        self.assertEqual(rc, 0)
        self.assertEqual(rows(out)["verdict"], "fresh")
        self.assertEqual(rows(out)["age"], "4 days")

    def test_pin_ahead_of_the_tip_is_not_a_negative_age(self):
        rc, out, _ = run(inject("2026-11-20", "2026-11-01"))
        self.assertEqual(rc, 0)
        self.assertEqual(rows(out)["age"], "0 days")
        self.assertEqual(rows(out)["verdict"], "fresh")


class BacklogTest(unittest.TestCase):
    """A young pin can still be sitting on a mountain of unabsorbed commits.

    Age answers "has upstream been quiet?"; it cannot answer "how much upstream
    work is unabsorbed" -- one busy morning is 143 commits without moving the
    date.  These cases pin the second axis, including the honest "unknown".
    """

    def test_young_and_heavy_is_a_backlog_not_fresh(self):
        rc, out, err = run(inject("2026-10-28", "2026-11-21", commits_behind=143))
        self.assertEqual(rc, 0, "a backlog is a warning, not a failed job")
        self.assertEqual(rows(out)["verdict"], "backlog")
        self.assertEqual(rows(out)["age"], "24 days")
        self.assertEqual(rows(out)["commits_behind"], "143")
        self.assertEqual(
            err.strip(),
            "backlog-pin: 143 commits behind (>= 50) while age is 24 days")

    def test_a_small_backlog_on_a_young_pin_stays_fresh(self):
        rc, out, err = run(inject("2026-10-28", "2026-11-21", commits_behind=49))
        self.assertEqual(rc, 0)
        self.assertEqual(rows(out)["verdict"], "fresh")
        self.assertEqual(rows(out)["commits_behind"], "49")
        self.assertEqual(err, "")

    def test_the_backlog_threshold_is_the_documented_default(self):
        # 50 is the default boundary: 49 fresh, 50 backlog.
        _, out, _ = run(inject("2026-10-28", "2026-11-21", commits_behind=50))
        self.assertEqual(rows(out)["verdict"], "backlog")

    def test_the_threshold_is_configurable(self):
        env = dict(inject("2026-10-28", "2026-11-21", commits_behind=143),
                   MT76_PIN_AGE_STALE_COMMITS="200")
        rc, out, err = run(env)
        self.assertEqual(rc, 0)
        self.assertEqual(rows(out)["verdict"], "fresh")
        self.assertEqual(err, "")

    def test_an_unknown_count_keeps_the_age_bands_but_says_so(self):
        rc, out, err = run(inject("2026-10-28", "2026-11-21"))
        self.assertEqual(rc, 0)
        self.assertEqual(rows(out)["verdict"], "fresh")
        self.assertEqual(rows(out)["commits_behind"], "unknown")
        self.assertEqual(err, "")

    def test_an_old_pin_stays_stale_even_with_a_backlog(self):
        # The day bands are not replaced by the commit axis: 50 days behind is
        # stale whether or not the commit count is known.
        rc, out, err = run(inject("2026-10-01", "2026-11-20", commits_behind=143))
        self.assertEqual(rc, 0)
        self.assertEqual(rows(out)["verdict"], "stale")
        self.assertEqual(err.strip(), "stale-pin: 50 days behind")

    def test_an_unreadable_upstream_is_still_blocked(self):
        rc, out, _ = run({"MT76_PIN_AGE_UNDER_TEST":
                          "pin_date=2026-10-28 upstream_date= commits_behind=143"})
        self.assertEqual(rc, 2)
        self.assertEqual(rows(out)["verdict"], "blocked")


class ReaderTest(unittest.TestCase):
    """The real path: Makefile -> pin, bare cache -> tip, then the date math."""

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        home = self.root / "home"
        home.mkdir()
        self.env = {
            "HOME": str(home),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        }

    def make_upstream(self, dates):
        """A repository whose master tip is the last of `dates`; returns shas."""
        repo = self.root / "upstream"
        subprocess.run(["git", "init", "-q", "-b", "master", str(repo)],
                       check=True, env=self.env, capture_output=True)
        shas = []
        for stamp in dates:
            when = "%sT00:00:00+0000" % stamp
            subprocess.run(["git", "-C", str(repo), "commit", "-q", "--allow-empty",
                            "-m", "c%s" % stamp, "--date", when],
                           check=True, env=dict(self.env, GIT_COMMITTER_DATE=when,
                                                GIT_AUTHOR_DATE=when),
                           capture_output=True)
            shas.append(subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"],
                                       check=True, capture_output=True, text=True,
                                       env=self.env).stdout.strip())
        return repo, shas

    def write_pin(self, pin_date, pin_sha):
        path = self.root / "Makefile"
        path.write_text(PIN_TEMPLATE.format(pin_date=pin_date, pin_sha=pin_sha),
                        encoding="utf-8")
        return path

    def test_reads_the_makefile_and_the_cache_tip(self):
        repo, shas = self.make_upstream(["2026-10-08", "2026-10-20"])
        pin = self.write_pin("2026-10-08", shas[0])
        rc, out, err = run(dict(self.env, MT76_PIN_FILE=str(pin),
                                MT76_PIN_AGE_REPO=str(repo)))
        self.assertEqual(rc, 0)
        self.assertEqual(rows(out)["pin"], "2026-10-08 (%s)" % shas[0][:8])
        self.assertEqual(rows(out)["upstream master"], "2026-10-20 (%s)" % shas[1][:8])
        self.assertEqual(rows(out)["age"], "12 days")
        self.assertEqual(rows(out)["commits_behind"], "1",
                         "the cache holds the pin, so the count is measured")
        self.assertEqual(rows(out)["verdict"], "fresh")
        self.assertEqual(err, "")

    def test_a_pin_missing_from_the_cache_is_unknown_not_fresh(self):
        # A shallow or truncated cache cannot count; the row must say so
        # instead of showing a number nobody measured.
        repo, shas = self.make_upstream(["2026-10-08", "2026-10-20"])
        pin = self.write_pin("2026-10-08", "0" * 40)
        rc, out, _ = run(dict(self.env, MT76_PIN_FILE=str(pin),
                              MT76_PIN_AGE_REPO=str(repo)))
        self.assertEqual(rc, 0)
        self.assertEqual(rows(out)["commits_behind"], "unknown")
        self.assertEqual(rows(out)["verdict"], "fresh")

    def test_a_missing_cache_is_blocked_and_names_the_fix(self):
        pin = self.write_pin("2026-10-08", "46b67e5b7c49313d11b2b2d83df3c8025406d63e")
        rc, out, _ = run(dict(self.env, MT76_PIN_FILE=str(pin),
                              MT76_PIN_AGE_REPO=str(self.root / "no-cache")))
        self.assertEqual(rc, 2)
        self.assertEqual(rows(out)["verdict"], "blocked")
        self.assertEqual(rows(out)["upstream master"], "unavailable")
        self.assertIn("run once with --fetch", rows(out)["reason"])

    def test_a_bad_pin_date_is_blocked_not_a_traceback(self):
        repo, shas = self.make_upstream(["2026-10-20"])
        pin = self.write_pin("not-a-date", shas[0])
        rc, out, _ = run(dict(self.env, MT76_PIN_FILE=str(pin),
                              MT76_PIN_AGE_REPO=str(repo)))
        self.assertEqual(rc, 2)
        self.assertEqual(rows(out)["verdict"], "blocked")
        self.assertIn("YYYY-MM-DD", rows(out)["reason"])

    def test_an_empty_pin_file_is_blocked_not_a_traceback(self):
        pin = self.root / "Makefile"
        pin.write_text("PKG_NAME:=mt76\n", encoding="utf-8")
        rc, out, _ = run(dict(self.env, MT76_PIN_FILE=str(pin),
                              MT76_PIN_AGE_REPO=str(self.root / "no-cache")))
        self.assertEqual(rc, 2)
        self.assertEqual(rows(out)["pin"], "unavailable (unknown)")
        self.assertEqual(rows(out)["verdict"], "blocked")


class WorkflowTest(unittest.TestCase):
    """The scheduler must stay a monthly age check, not the quarterly gate."""

    def test_monthly_schedule_is_its_own(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("cron: '43 6 2 * *'", text)
        # #336's expression (a Monday in days 1-7) carries a quarter gate that
        # answers a different question; borrowing it would make one run mean
        # two things.  Only the cron lines are inspected: the comment above may
        # name the other expression.
        cron = "\n".join(line for line in text.splitlines()
                         if line.strip().startswith(("- cron:", "cron:")))
        self.assertNotIn("1-7 * 1", cron)

    def test_manual_dispatch_remains_possible(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
