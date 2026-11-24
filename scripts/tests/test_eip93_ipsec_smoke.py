#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""result.json must not say pass without an ESP packet on each SPI.

`scripts/eip93-ipsec-smoke.sh` is the only evidence source behind the EIP93
offload claims.  A module refcount that rose when the SA was *allocated* is
not evidence that a single packet used it: a selector typo, `-R` on the
wrong direction, or SNAT ahead of the policy lookup leaves the iperf3 flow
in cleartext while the refcount still reads high.  The script therefore has
to read the kernel's per-SA counters (`lifetime current: ... (packets)`)
from both ends and fail on zero.

Red half (script at 42c216064b): the script never runs `ip xfrm state`, so
`result.json` has no `packets_out`/`packets_in`, and a run whose SAs carry
zero packets still exits 0 with `ok: true`.  The first two cases fail; the
third (`refcount fell after the run`) fails because only the after-Setup
refcount is compared.

Second red half (script at 6db02b23a8): the counters were parsed off the
`lifetime current:` line itself and the SPI was compared verbatim against
`$4`, but `ip -s xfrm state list` prints the counters on the *next* line and
the SPI as `0x%08x(%u)` - so every real run failed with "cannot read the ESP
packet counter".  The fixture below is that real shape, not a one-liner;
`test_spi_padding_and_the_counter_line` is the case the one-line fixture
could never reach.

The script under test is a copy with `MODPATH`/`PROC_CRYPTO` pointed at
fixtures; `ip`, `iperf3`, `ssh` and `id` are stubs on PATH, so no device, no
root and no xfrm state are involved.  EIP93_SCRIPT_UNDER_TEST points the
test at another copy.

    python3 scripts/tests/test_eip93_ipsec_smoke.py
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get("EIP93_SCRIPT_UNDER_TEST", REPO / "scripts/eip93-ipsec-smoke.sh")
)

ID_STUB = """\
#!/bin/sh
case "$*" in
*-u*) printf '0\\n' ;;
*) exec /usr/bin/id "$@" ;;
esac
"""

IP_STUB = """\
#!/bin/sh
printf '%s\\n' "$*" >>"${IP_LOG:?}"
case "$*" in
*"xfrm state add"*)
	n=$(cat "$REF_FIXTURE" 2>/dev/null || printf '0')
	printf '%s\\n' $((n + 1)) >"$REF_FIXTURE"
	exit 0
	;;
*"xfrm state list"*)
	cat "$STATE_FIXTURE"
	exit 0
	;;
esac
exit 0
"""

SSH_STUB = """\
#!/bin/sh
for last; do :; done
exec sh -c "$last"
"""

IPERF3_STUB = """\
#!/bin/sh
case "$1" in
--version)
	printf 'iperf 3.17\\n'
	exit 0
	;;
esac
cat <<'EOF'
{
  "end": {
    "sum_sent": {
      "bits_per_second": 1234567890,
      "bytes": 1000000000,
      "seconds": 10.0,
      "retransmits": 0
    }
  }
}
EOF
[ -n "${IPERF_HOOK:-}" ] && sh -c "$IPERF_HOOK"
exit 0
"""

PROC_CRYPTO = """\
name         : authenc(hmac(sha1),cbc(aes))
driver       : eip93-esp-aes
priority     : 1500
"""

# One SA as `ip -s xfrm state list` prints it (iproute2 6.18, ip/ipxfrm.c:
# `spi 0x%08x(%u)` under `-s`, then "lifetime current:" on its own line with
# "  %llu(bytes), %llu(packets)" under it).  A one-line fixture is a shape
# `ip` never prints.
REAL_SA = """\
src {src} dst {dst}
\tproto esp spi {spi}({dec}) reqid 0(0x00000000) mode transport
\treplay-window 0
\tauth-trunc hmac(sha1) 96 160
\tenc cbc(aes)
\tsel src 0.0.0.0/0 dst 0.0.0.0/0
\tlifetime config:
\t  (INF)(bytes), (INF)(packets)
\tlifetime current:
\t  {nbytes}(bytes), {packets}(packets)
\t  add 2026-11-24 14:43:12 use -
"""


def sa_block(spi: str, nbytes: int, packets: int, src: str, dst: str) -> str:
    """One SA block, SPI printed the way `ip -s` prints it."""
    return REAL_SA.format(
        src=src,
        dst=dst,
        spi="0x%08x" % int(spi, 16),
        dec=int(spi, 16),
        nbytes=nbytes,
        packets=packets,
    )


def _write_exec(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


class Eip93EspCounters(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="eip93-smoke."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for name, text in (
            ("id", ID_STUB),
            ("ip", IP_STUB),
            ("ssh", SSH_STUB),
            ("iperf3", IPERF3_STUB),
        ):
            _write_exec(self.bin / name, text)

        self.refcnt = self.tmp / "refcnt"
        self.refcnt.write_text("1\n")
        self.proc_crypto = self.tmp / "proc_crypto"
        self.proc_crypto.write_text(PROC_CRYPTO)

        self.script = self.tmp / "eip93-ipsec-smoke.sh"
        source = SCRIPT.read_text(encoding="utf-8")
        source = re.sub(
            r"^MODPATH=.*$",
            'MODPATH="%s"' % self.refcnt,
            source,
            count=1,
            flags=re.M,
        )
        source = re.sub(
            r"^PROC_CRYPTO=.*$",
            "PROC_CRYPTO=%s" % self.proc_crypto,
            source,
            count=1,
            flags=re.M,
        )
        self.script.write_text(source, encoding="utf-8")

        self.env = dict(os.environ)
        self.env["PATH"] = "%s:%s" % (self.bin, self.env.get("PATH", ""))
        self.env["REF_FIXTURE"] = str(self.refcnt)
        self.env["IP_LOG"] = str(self.tmp / "ip.log")

    def run_script(
        self,
        out_name: str,
        packets: int = 42,
        hook: str = "",
        spi_out: str = "0xe1930001",
        spi_in: str = "0xe1930002",
        foreign_sa: tuple[str, int] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        state = self.tmp / "xfrm-state.txt"
        blocks = []
        if foreign_sa is not None:
            # An SA that is not ours, with counters no test wants to record.
            blocks.append(
                sa_block(
                    foreign_sa[0],
                    foreign_sa[1] * 1000,
                    foreign_sa[1],
                    "10.0.0.9",
                    "10.0.0.10",
                )
            )
        blocks.append(sa_block(spi_out, 123456, packets, "10.0.0.1", "10.0.0.2"))
        blocks.append(sa_block(spi_in, 654321, packets, "10.0.0.2", "10.0.0.1"))
        state.write_text("\n".join(blocks), encoding="utf-8")

        out = self.tmp / out_name
        env = dict(self.env)
        env["STATE_FIXTURE"] = str(state)
        if hook:
            env["IPERF_HOOK"] = hook
        proc = subprocess.run(
            [
                "sh",
                str(self.script),
                "--local",
                "10.0.0.1",
                "--peer",
                "10.0.0.2",
                "--peer-ssh",
                "peer",
                "--duration",
                "1",
                "--spi-out",
                spi_out,
                "--spi-in",
                spi_in,
                "--out",
                str(out),
            ],
            capture_output=True,
            text=True,
            timeout=120,
            env=env,
            check=False,
        )
        return proc, out

    def test_records_both_esp_counters_in_result_json(self):
        proc, out = self.run_script("passing.json")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        record = json.loads(out.read_text(encoding="utf-8"))
        self.assertTrue(record["ok"])
        esp = record["esp"]
        self.assertEqual(esp["packets_out"], 42, esp)
        self.assertEqual(esp["packets_in"], 42, esp)
        self.assertEqual(esp["bytes_out"], 123456, esp)
        self.assertEqual(esp["bytes_in"], 654321, esp)
        self.assertIn("ESP packets", proc.stdout)

    def test_zero_packets_means_the_flow_bypassed_the_policy(self):
        proc, out = self.run_script("cleartext.json", packets=0)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("no ESP packet on SPI 0xe1930001", proc.stderr)
        self.assertIn("cleartext", proc.stderr)
        record = json.loads(out.read_text(encoding="utf-8"))
        self.assertFalse(record["ok"])
        self.assertIn("no ESP packet", record["error"])
        self.assertEqual(record["esp"]["packets_out"], 0)

    def test_refcount_that_falls_after_the_run_is_a_failure(self):
        hook = 'printf "1\\n" >"$REF_FIXTURE"'
        proc, out = self.run_script("refcount-fell.json", hook=hook)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("refcount fell after the run", proc.stderr)
        record = json.loads(out.read_text(encoding="utf-8"))
        self.assertFalse(record["ok"])

    def test_spi_padding_and_the_counter_line(self):
        # `--spi-out 0x100` is the SA `ip -s` prints as `spi 0x00000100(256)`;
        # the leading zeros and the decimal suffix must not hide the counters.
        proc, out = self.run_script(
            "padded-spi.json", spi_out="0x100", spi_in="0x200"
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        record = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(record["esp"]["packets_out"], 42, record["esp"])
        self.assertEqual(record["esp"]["packets_in"], 42, record["esp"])

    def test_counters_come_from_the_requested_sa_only(self):
        # Another SA with a bigger counter appears first: an awk that kept
        # the last counter it saw, or ignored the SPI, would record 999.
        proc, out = self.run_script(
            "foreign-sa.json", foreign_sa=("0x000000ff", 999)
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        record = json.loads(out.read_text(encoding="utf-8"))
        esp = record["esp"]
        self.assertEqual(esp["packets_out"], 42, esp)
        self.assertEqual(esp["packets_in"], 42, esp)


if __name__ == "__main__":
    unittest.main()
