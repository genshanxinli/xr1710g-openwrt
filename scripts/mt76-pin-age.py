#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""mt76-pin-age.py -- how many upstream days is the mt76 pin behind? (#9).

Read-only.  The pin is the pair in package/kernel/mt76/Makefile:

    PKG_SOURCE_DATE:=2026-10-28
    PKG_SOURCE_VERSION:=46b67e5b...

and the age is the distance in whole days between that declared date and the
commit date of the *real* upstream tip:

    age = upstream_tip_date - PKG_SOURCE_DATE

Why the real upstream (openwrt/mt76, branch master) and not the fork the pin
points at (OpenWRT-fanboy/mt76-firmware, branch main): the fork is a mirror,
so asking it answers "how stale is the mirror", which stays quiet for as long
as nobody resyncs the mirror -- exactly the blind spot this check exists to
remove.  scripts/check-mt76-pin.sh answers the other question (is the pin far
from the branch we clone, in commits, patch-set aware); this script answers
"how much upstream time has piled up since we pinned", and the two are
deliberately separate contracts over two separate readers.  openwrt/mt76 has
no `refs/heads/main`; its default branch is `master` (checked with
`git ls-remote https://github.com/openwrt/mt76`), so the output row names the
branch it read.

Why a date difference and not "today minus the pin": a pin that sits on an
upstream that has not moved is not behind anything.  #9 wants a warning when
unabsorbed upstream work piles up, so a quiet upstream must stay quiet here no
matter how old the pin itself becomes.

verdict / exit status (the workflow keys on both):

  fresh    age <= 30 and fewer than MT76_PIN_AGE_STALE_COMMITS commits behind
                                                       exit 0
  backlog  age <= 30 but >= MT76_PIN_AGE_STALE_COMMITS commits behind
                         exit 0, plus one `backlog-pin: N commits behind` line
                         on stderr (a green run with a ::warning:: annotation:
                         the upstream is young but has piled up unabsorbed
                         work, which the age band alone cannot see)
  stale    31 .. 90      exit 0, plus one `stale-pin: N days behind` line on
                         stderr (a green run with a ::warning:: annotation)
  blocked  age > 90, or the pin date / upstream tip is unreadable
                         exit 2, plus a `reason:` row (a workflow turns this
                         into ::error:: and a red run: a scheduled run that
                         goes red is the only notification this repository
                         gets without an SMTP setup, and a silent "fresh" when
                         upstream could not be read is the failure this
                         contract prevents.)

The commit count is the second axis on purpose.  Age answers "has the upstream
been quiet?" -- which is the right question for a pin that sits on a moving
branch over months.  It cannot answer "how much upstream work is unabsorbed":
one busy morning upstream is 143 commits while the date barely moves.  Both
rows are printed, so a reader can see which one decided the verdict.  When the
count cannot be read (--offline without the pin commit in the cache, or a
shallow cache), the row says `commits_behind: unknown` and the age bands decide
alone -- the same behaviour as before this axis existed, but never a claim that
the count was checked.

Offline is the default, like check-mt76-pin.sh: the upstream cache is a local
input, `--fetch` refreshes or creates it.  Without a cache the pin rows still
come out of the Makefile -- that is the local information an offline run has --
and the verdict is blocked, never fresh.

Usage:
  scripts/mt76-pin-age.py [--fetch|--offline] [--pin-file FILE]
                          [--repo DIR] [--ref REF] [-h|--help]

Output rows (machine-readable, `key: value`):

  pin: DATE (SHORT_SHA)
  upstream BRANCH: DATE (SHORT_SHA) | unavailable
  age: N days | unknown
  commits_behind: N | unknown
  verdict: fresh|backlog|stale|blocked
  reason: ...                       (blocked only)

Environment:
  MT76_PIN_FILE              default package/kernel/mt76/Makefile
  MT76_PIN_AGE_REPO          default <git-common-dir>/mt76-openwrt.git
  MT76_PIN_AGE_REF           default master
  MT76_PIN_AGE_URL           default https://github.com/openwrt/mt76
  MT76_PIN_AGE_STALE_COMMITS default 50; a young pin (age <= 30) with this many
                             unabsorbed commits is a backlog, not fresh
  MT76_PIN_AGE_UNDER_TEST    "key=value ..." injection for the tests:
                             pin_date, pin_sha, upstream_date (absent or empty
                             means "upstream unreadable"), upstream_sha,
                             upstream_ref, commits_behind (absent or empty means
                             "not countable").  It skips the Makefile and git.
"""

import os
import re
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

FRESH_MAX = 30
STALE_MAX = 90

DEFAULT_UPSTREAM_URL = "https://github.com/openwrt/mt76"
DEFAULT_REF = "master"
DEFAULT_STALE_COMMITS = 50


def usage_error(message):
    print("mt76-pin-age: %s" % message, file=sys.stderr)
    sys.exit(2)


def stale_commits_limit():
    raw = os.environ.get("MT76_PIN_AGE_STALE_COMMITS", str(DEFAULT_STALE_COMMITS))
    try:
        return int(raw)
    except ValueError:
        usage_error("MT76_PIN_AGE_STALE_COMMITS wants an integer, got %r" % raw)


def short(sha):
    return sha[:8] if sha else "unknown"


def read_pin(path):
    """(date, sha) as declared in the Makefile; missing fields are ''."""
    try:
        body = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return "", ""
    found = {}
    for key, field in (("PKG_SOURCE_DATE", "date"), ("PKG_SOURCE_VERSION", "sha")):
        match = re.search(r"^%s:=(\S+)" % key, body, re.MULTILINE)
        found[field] = match.group(1) if match else ""
    return found["date"], found["sha"]


def git(args, cwd=None, timeout=120):
    """Run git quietly; (rc, stdout, stderr).  Missing git is rc 127."""
    try:
        done = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=dict(os.environ, GIT_TERMINAL_PROMPT="0"),
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "", str(exc)
    return done.returncode, done.stdout.strip(), done.stderr.strip()


def cache_path():
    top = Path(__file__).resolve().parents[1]
    rc, common, _ = git(["rev-parse", "--path-format=absolute", "--git-common-dir"],
                         cwd=str(top))
    if rc == 0 and common:
        return Path(common) / "mt76-openwrt.git"
    return Path(os.environ.get("TMPDIR", "/tmp")) / "mt76-openwrt.git"


def is_shallow(repo):
    rc, out, _ = git(["-C", str(repo), "rev-parse", "--is-shallow-repository"])
    return rc == 0 and out == "true"


def refresh(repo, ref, url):
    """Create or update the bare cache.  Returns '' on success, else a reason."""
    clone = not repo.exists()
    last = ""
    # Two attempts: a monthly cron should survive one flaky TLS handshake, and
    # the second attempt is free when the first one worked.
    for _ in range(2):
        if clone:
            # No --depth: a shallow cache cannot answer "how many commits
            # behind", which is the second half of the verdict below.
            args = ["clone", "-q", "--bare", "--branch", ref, url, str(repo)]
            what = "clone from %s (branch %s)" % (url, ref)
        else:
            if is_shallow(repo):
                # Caches created by older runs are depth-1; deepen once so the
                # commit count stops being unknown.
                git(["-C", str(repo), "fetch", "-q", "--unshallow", "--prune",
                     "origin"])
            # An explicit refspec keeps the update independent of the remote
            # config: no remote refspec is assumed.
            args = ["-C", str(repo), "fetch", "-q", "--prune",
                    "origin", "+refs/heads/%s:refs/heads/%s" % (ref, ref)]
            what = "fetch in %s (branch %s)" % (repo, ref)
        rc, _, err = git(args)
        if rc == 0:
            return ""
        last = err or "git exit %d" % rc
        if clone:
            shutil.rmtree(str(repo), ignore_errors=True)
    return "%s failed: %s" % (what, last)


def upstream_tip(repo, ref):
    """(date, sha) of the cache's branch tip, ('', '') when unreadable."""
    rc, sha, _ = git(["-C", str(repo), "rev-parse", "-q", "--verify",
                      "refs/heads/%s^{commit}" % ref])
    if rc != 0 or not sha:
        return "", ""
    rc, tip_date, _ = git(["-C", str(repo), "log", "-1", "--format=%cs", sha])
    if rc != 0 or not tip_date:
        return sha, ""
    return tip_date, sha


def commits_behind(repo, pin_sha, tip_sha):
    """Commits reachable from tip_sha and not from pin_sha; None when uncountable.

    None is not zero: a shallow cache, a pin that predates the cache or a pin
    on another lineage all mean "the count was not measured", and the caller
    prints `commits_behind: unknown` rather than a made-up number.
    """
    if not pin_sha or not tip_sha:
        return None
    rc, _, _ = git(["-C", str(repo), "cat-file", "-e", "%s^{commit}" % pin_sha])
    if rc != 0:
        return None
    rc, _, _ = git(["-C", str(repo), "merge-base", "--is-ancestor",
                    pin_sha, tip_sha])
    if rc != 0:
        return None
    rc, out, _ = git(["-C", str(repo), "rev-list", "--count",
                      "%s..%s" % (pin_sha, tip_sha)])
    if rc != 0 or not out.isdigit():
        return None
    return int(out)


def age_in_days(pin_date, tip_date):
    """Whole days between the two YYYY-MM-DD dates; None when either is bad."""
    try:
        return (date.fromisoformat(tip_date) - date.fromisoformat(pin_date)).days
    except ValueError:
        return None


def override():
    spec = os.environ.get("MT76_PIN_AGE_UNDER_TEST")
    if not spec:
        return None
    values = {}
    for token in spec.split():
        key, sep, value = token.partition("=")
        if not sep:
            usage_error("MT76_PIN_AGE_UNDER_TEST wants key=value tokens, got %r" % token)
        values[key] = value
    return values


def main(argv):
    pin_file = os.environ.get(
        "MT76_PIN_FILE",
        str(Path(__file__).resolve().parents[1] / "package/kernel/mt76/Makefile"))
    repo = Path(os.environ.get("MT76_PIN_AGE_REPO") or cache_path())
    ref = os.environ.get("MT76_PIN_AGE_REF", DEFAULT_REF)
    url = os.environ.get("MT76_PIN_AGE_URL", DEFAULT_UPSTREAM_URL)
    fetch = False

    args = list(argv[1:])
    while args:
        arg = args.pop(0)
        if arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        if arg == "--fetch":
            fetch = True
        elif arg == "--offline":
            fetch = False
        elif arg in ("--pin-file", "--repo", "--ref", "--url"):
            if not args:
                usage_error("%s needs a value" % arg)
            value = args.pop(0)
            if arg == "--pin-file":
                pin_file = value
            elif arg == "--repo":
                repo = Path(value)
            elif arg == "--ref":
                ref = value
            else:
                url = value
        else:
            usage_error("unknown argument: %s" % arg)

    tip_date, tip_sha, problem = "", "", ""
    behind = None
    stale_commits = stale_commits_limit()
    injected = override()
    if injected:
        pin_date = injected.get("pin_date", "")
        pin_sha = injected.get("pin_sha", "")
        ref = injected.get("upstream_ref", ref)
        tip_date = injected.get("upstream_date", "")
        tip_sha = injected.get("upstream_sha", "")
        problem = "" if tip_date else "test injection: upstream_date is absent"
        raw_behind = injected.get("commits_behind", "")
        if raw_behind:
            if not raw_behind.isdigit():
                usage_error("MT76_PIN_AGE_UNDER_TEST commits_behind wants an "
                            "integer, got %r" % raw_behind)
            behind = int(raw_behind)
    else:
        pin_date, pin_sha = read_pin(pin_file)
        if fetch:
            problem = refresh(repo, ref, url)
        if not problem and repo.is_dir():
            tip_date, tip_sha = upstream_tip(repo, ref)
            if not tip_date:
                problem = "no readable %s tip in %s; run once with --fetch" % (ref, repo)
            else:
                behind = commits_behind(repo, pin_sha, tip_sha)
        elif not problem:
            problem = "no upstream cache at %s; run once with --fetch" % repo

    print("pin: %s (%s)" % (pin_date or "unavailable", short(pin_sha)))
    if tip_date:
        print("upstream %s: %s (%s)" % (ref, tip_date, short(tip_sha)))
    else:
        print("upstream %s: unavailable" % ref)

    days = age_in_days(pin_date, tip_date) if tip_date else None
    if days is not None and days < 0:
        # A pin date ahead of the upstream tip is a declaration bug, not a
        # negative drift; report it as 0 and let the reviewer look at the pin.
        days = 0
    print("age: %s" % ("%d days" % days if days is not None else "unknown"))
    print("commits_behind: %s" % ("%d" % behind if behind is not None else "unknown"))

    if days is None:
        print("verdict: blocked")
        print("reason: %s" % (problem or "pin date %r is not YYYY-MM-DD" % pin_date))
        return 2
    if days <= FRESH_MAX:
        if behind is not None and behind >= stale_commits:
            # Young by date, heavy by commits: the age band alone cannot say
            # this, and calling it fresh is the blind spot this axis removes.
            print("verdict: backlog")
            print("backlog-pin: %d commits behind (>= %d) while age is %d days"
                  % (behind, stale_commits, days), file=sys.stderr)
            return 0
        print("verdict: fresh")
        return 0
    if days <= STALE_MAX:
        print("verdict: stale")
        print("stale-pin: %d days behind" % days, file=sys.stderr)
        return 0
    print("verdict: blocked")
    print("reason: pin is %d days behind upstream %s (> %d)" % (days, ref, STALE_MAX))
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
