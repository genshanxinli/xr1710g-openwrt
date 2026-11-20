#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guard the tr(1) operands of scripts that run on the XR1710G itself.

BusyBox v1.38.0 on the router (r38047, /usr/bin/tr) does not implement the
POSIX character classes.  Measured on the device:

    $ printf 'cn\n' | tr '[:lower:]' '[:upper:]'   -> cn
    $ printf 'cn\n' | tr 'a-z' 'A-Z'               -> CN
    $ printf 'a b\tc\n' | tr -d '[:space:]'        -> ' b\t'   (a and c eaten)
    $ printf 'a b\tc\n' | tr -d ' \t\n'            -> abc

So a device-side script may only use literal ranges and escapes as operands.
This test enumerates every tr invocation in the scripts that ship to (or are
documented to be run on) the router, and replays each invocation through a
stand-in that reproduces the BusyBox behaviour, comparing it byte for byte
with the host tr.  A regression back to the class form fails here on any host.

Host-side harnesses (they pipe stderr of a remote command through the local
GNU tr) are deliberately not listed.

Run from the repository root:

    python3 scripts/tests/test_tr_busybox_operands.py
"""

import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Every file here executes on the router: wifi-reg-report.sh is documented as
# "ssh root@xr1710g sh /tmp/wifi-reg-report.sh", the wireless bench harnesses
# say "On the AP" / "runs on the AP", pcie-single-cut.sh and npu-fw-ab.sh
# drive devmem and /proc on the board, and trafficchart-persist-exec is an
# installed /usr/libexec script.
DEVICE_FILES = (
    "scripts/wifi-reg-report.sh",
    "scripts/pcie-single-cut.sh",
    "scripts/wireless/6g320-matrix.sh",
    "scripts/wireless/a-path-multisocket.sh",
    "scripts/wireless/irq-napi-ab.sh",
    "scripts/wireless/npu-fw-ab.sh",
    "package/luci-app-traffic-chart/root/usr/libexec/trafficchart-persist-exec",
)

# `tr` at command position, quoted operands, stop before the shell separator.
TR_CALL = re.compile(
    r"(?:^|[|;&(`\s])tr\s+((?:'[^']*'|\"[^\"]*\"|[^|;&)\n`])+)")

# BusyBox v1.38.0: classes are not expanded.  Substitution copies the operand
# through; -d/-c deletes the characters the unexpanded operand happens to
# contain.  Either way the result differs from a host tr, which is all this
# test relies on.
TR_STUB = '''#!/usr/bin/env python3
import os, sys

args = sys.argv[1:]
opts = [a for a in args if a.startswith("-")]
operands = [a for a in args if not a.startswith("-")]


def unescape(text):
    out = []
    i = 0
    while i < len(text):
        if text[i] == "\\\\" and i + 1 < len(text):
            out.append({"n": "\\n", "t": "\\t", "r": "\\r", "\\\\": "\\\\"}.get(
                text[i + 1], text[i + 1]))
            i += 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


if any("[:" in o for o in operands):
    data = sys.stdin.buffer.read()
    joined = "".join(opts)
    if "-d" in joined or "-c" in joined:
        unwanted = set(unescape("".join(operands)).encode())
        sys.stdout.buffer.write(bytes(b for b in data if b not in unwanted))
    else:
        sys.stdout.buffer.write(data)
    sys.exit(0)

os.execv(os.environ["REAL_TR"], [os.environ["REAL_TR"]] + args)
'''


def real_tr():
    found = shutil.which("tr")
    if not found:
        raise unittest.SkipTest("no tr(1) on this host")
    return found


def tr_calls():
    """Yield (file, line number, argv-after-tr) for every device-side call."""
    for name in DEVICE_FILES:
        path = REPO_ROOT / name
        if not path.exists():
            raise unittest.SkipTest("missing %s" % name)
        for lineno, line in enumerate(
                path.read_text(errors="replace").splitlines(), 1):
            # A comment may quote the broken form to explain why it is gone.
            if line.lstrip().startswith("#"):
                continue
            for match in TR_CALL.finditer(line):
                yield name, lineno, _split(match.group(1))


def _split(text):
    lexer = shlex.shlex(text, posix=True)
    lexer.whitespace_split = True
    return list(lexer)


class BusyBoxTrOperandTest(unittest.TestCase):
    def setUp(self):
        self.tr = real_tr()
        self.tmp = tempfile.mkdtemp(prefix="bbtr-")
        self.stub = Path(self.tmp) / "bb-tr"
        self.stub.write_text(TR_STUB)
        self.stub.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_operands_are_class_free(self):
        offenders = [
            "%s:%d: tr %s" % (name, lineno, " ".join(argv))
            for name, lineno, argv in tr_calls()
            if any("[:" in arg for arg in argv)
        ]
        self.assertEqual(
            offenders, [],
            "tr operand uses a POSIX class that BusyBox does not expand; "
            "use 'a-z' 'A-Z' or an explicit ' \\t\\n' set instead")

    def test_operands_behave_like_host_tr_under_busybox(self):
        calls = list(tr_calls())
        self.assertTrue(calls, "no tr call found in the device scripts")
        for name, lineno, argv in calls:
            want = self._run([self.tr] + argv)
            got = self._run([sys.executable, str(self.stub)] + argv)
            self.assertEqual(
                got, want, "%s:%d: tr %s is not BusyBox-safe"
                % (name, lineno, " ".join(argv)))

    def _run(self, command):
        # Probe covers what the call sites touch: case, spaces, tabs,
        # newlines, digits and hex letters.  Operands are passed as argv, not
        # re-quoted, so a literal backslash-n reaches tr the way sh passes it.
        env = dict(os.environ, REAL_TR=self.tr)
        return subprocess.run(
            command, input=b"a b\tc\nCN cn 1 2\n0x7f\t  10\n",
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


if __name__ == "__main__":
    unittest.main()
