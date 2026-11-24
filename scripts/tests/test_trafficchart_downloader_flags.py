#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""trafficchart-domains-update must only pass flags every OpenWrt downloader knows.

Reproduced on the XR1710G (r38047, 2026-11-22 21:53:12), every boot:

    user.notice trafficchart: v2fly domain list update failed: download failed:
    dlc.dat_plain.yml - wget: unrecognized option: t
    Usage: wget [options] <URL>
    Options: -4 Use IPv4 only -6 Use IPv6 only -O <file> Redirect output to
    file (use "-" for stdout) -P <dir> Set directory for output files ...

That usage text is uclient-fetch's, installed as ``wget`` on this image, so the
``-t 2`` (GNU wget's --tries) the script passed was rejected before a single
byte was downloaded. ``-t``/``--tries`` is in neither uclient-fetch nor the
BusyBox wget applet, and the script's own downloader fallback list is exactly
those two (plus curl).

What is asserted, offline:

  * every ``run_fetch wget ...`` / ``run_fetch uclient-fetch ...`` invocation in
    the shipped script passes only options inside the intersection of the flag
    sets of uclient-fetch, BusyBox wget and GNU wget;
  * the check itself catches the defect: replaying the historical
    ``wget -T 120 -t 2 -O dst url`` line through the same stand-in must fail
    with "unrecognized option: t".

Red half: point the variable at a copy with the old flag restored and the test
fails on the first invocation that matters:

    TRAFFICCHART_DOMAINS_UPDATE_UNDER_TEST=/tmp/copy/domains-update \\
        python3 -m unittest scripts.tests.test_trafficchart_downloader_flags

Run from the repository root:

    python3 scripts/tests/test_trafficchart_downloader_flags.py
"""

import os
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "TRAFFICCHART_DOMAINS_UPDATE_UNDER_TEST",
        REPO_ROOT / "package/luci-app-traffic-chart/root/usr/libexec/trafficchart-domains-update",
    )
)

# Options every downloader in the script's fallback list accepts.
#   uclient-fetch getopt: "46cO:P:qsT:U:vY:" (build_dir/.../uclient-fetch.c:700)
#   busybox wget usage:   [-cqS] [--spider] [-O FILE] [-o LOGFILE]
#                         [--header STR] [--post-data STR | --post-file FILE]
#                         [-Y on/off] [-P DIR] [-U AGENT] [-T SEC]
#   GNU wget:             all of the above (plus -t/--tries, which the other
#                         two lack -- that is the defect this test guards)
PORTABLE = {
    "-c", "-O", "-P", "-q", "-T", "-U", "-Y",
    "--header", "--no-check-certificate", "--post-data", "--post-file", "--spider",
}
NEEDS_ARG = {"-O", "-P", "-T", "-U", "-Y", "--header", "--post-data", "--post-file"}

# Stand-in for the router's downloader: parses options the way getopt does and
# fails on anything outside PORTABLE, without touching the network.
STUB = '''#!/usr/bin/env python3
import sys

allowed = @ALLOWED@
needs_arg = @NEEDS_ARG@
argv = sys.argv[1:]
i = 0
while i < len(argv):
    arg = argv[i]
    if arg == "--":
        break
    if arg.startswith("-") and arg != "-":
        name = arg.split("=", 1)[0]
        if name not in allowed:
            sys.stderr.write("%s: unrecognized option: %s\\n" % (
                sys.argv[0].rsplit("/", 1)[-1], name.lstrip("-")))
            sys.exit(1)
        if name in needs_arg and "=" not in arg:
            i += 1
    i += 1
sys.exit(0)
'''

FETCH_CALL = re.compile(
    r"\brun_fetch\s+(uclient-fetch|wget|curl)\s+([^\n;|&]*)")


def _stub(tmpdir: Path) -> Path:
    path = tmpdir / "wget"
    path.write_text(
        STUB.replace("@ALLOWED@", repr(PORTABLE))
        .replace("@NEEDS_ARG@", repr(NEEDS_ARG)),
        encoding="utf-8",
    )
    path.chmod(0o755)
    return path


def _invocations(text: str):
    """(line number, tool, argv without run_fetch) for every downloader call."""
    found = []
    for match in FETCH_CALL.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        tokens = shlex.split(match.group(0))
        # tokens[0] is run_fetch, tokens[1] the downloader.
        found.append((line, tokens[1], tokens[2:]))
    return found


class DownloaderFlags(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.stub = _stub(Path(self.tmp.name))

    def _replay(self, argv):
        return subprocess.run(
            [str(self.stub), *argv],
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_script_is_present(self):
        self.assertTrue(SCRIPT.is_file(), f"missing {SCRIPT}")

    def test_every_downloader_call_uses_portable_flags(self):
        invocations = _invocations(SCRIPT.read_text(encoding="utf-8"))
        self.assertTrue(invocations, "no run_fetch downloader call found")
        for line, tool, argv in invocations:
            # curl is a separate CLI (tried last) and has its own flag set.
            if tool == "curl":
                continue
            with self.subTest(line=line, tool=tool, argv=argv):
                result = self._replay(argv)
                self.assertEqual(
                    result.returncode,
                    0,
                    f"{SCRIPT.name}:{line} passes flags the router downloader "
                    f"rejects: {result.stderr.strip()}",
                )

    def test_stand_in_rejects_gnu_only_tries_flag(self):
        """Guard the guard: the historical line must fail this harness."""
        result = self._replay(["-T", "120", "-t", "2", "-O", "$dst", "$url"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrecognized option: t", result.stderr)


if __name__ == "__main__":
    unittest.main()
