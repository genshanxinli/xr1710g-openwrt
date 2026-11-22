"""--detach-port: the harness takes the data port out of its bridge itself.

Red half (both scripts at 5d8660fce9):

    $ sh scripts/wireless/2.5g-wired.sh --dry-run --detach-port ...
    2.5g-wired: unknown option: --detach-port

    $ sh scripts/wireless/b-path-25g.sh --dry-run --detach-port ...
    b-path-25g: unknown option: --detach-port

and with the flag accepted but nothing implemented, the device run still ended
in `BLOCKED: lan2 is in br-lan` plus a printed `ip link set lan2 nomaster`
that nobody ran (see scripts/wireless/2.5g-wired.sh, print_bridge_plan).

The detach/restore cases run for real: a private netns (`unshare -Urn`) with
a `br0` bridge and real veth pairs, `/sys` remounted so the new netdevs show
up there, and stub `ssh`/`ethtool`/`iperf3` on PATH so the actual harness
script runs unmodified.  Without CAP_NET_ADMIN for `ip link add type veth`
the case is skipped, never silently passed.

TWO_G5_SCRIPT_UNDER_TEST (or 2G5_SCRIPT_UNDER_TEST) and G25_BPATH_UNDER_TEST
point the tests at another copy of the scripts, which is how the red half is
produced.  The copy must keep the tree layout (`.../wireless/<script>` plus
`.../wireless/lib/*.sh`), because both scripts source their libraries from
"$(dirname "$0")/lib/".
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WIRED = Path(
    os.environ.get("TWO_G5_SCRIPT_UNDER_TEST")
    or os.environ.get("2G5_SCRIPT_UNDER_TEST")
    or REPO / "scripts/wireless/2.5g-wired.sh"
)
BPATH = Path(
    os.environ.get("G25_BPATH_UNDER_TEST")
    or REPO / "scripts/wireless/b-path-25g.sh"
)
LIB = WIRED.parent / "lib" / "port-detach.sh"

# Stubs: the "device" is this host.  ssh runs the remote command text
# locally; ethtool reports a 2500Mb/s full-duplex link on every port; iperf3
# never measures, records the live bridge state of the data port when
# SNAP_FILE is set (that is the mid-run evidence), and can delete the bridge
# once the port is already out of it (DROP_BRIDGE=1) to force a failing
# restore.
SSH_STUB = """\
#!/bin/sh
eval "cmd=\\${$#}"
exec sh -c "$cmd"
"""
ETHTOOL_STUB = """\
#!/bin/sh
case "$1" in
-i)
	printf 'driver: veth\\nversion: 1.0\\n'
	exit 0
	;;
esac
printf 'Settings for %s:\\n' "${1:-eth0}"
printf '\\tSpeed: 2500Mb/s\\n\\tDuplex: Full\\n'
printf '\\tSupported link modes:   2500baseT/Full\\n'
printf '\\tAdvertised link modes:  2500baseT/Full\\n'
printf '\\tLink detected: yes\\n'
"""
IW_STUB = """\
#!/bin/sh
# The client must look associated so the run reaches the detach; the arms
# fail on their own and the case is about the detach and the restore.
case "$*" in
*"station dump"*) printf 'Station 02:00:00:00:00:09 (on %s)\n' "$2" ;;
esac
exit 0
"""
IPERF3_STUB = """\
#!/bin/sh
# $1 is the data port the harness is driving.
port=${STUB_PORT:-lan2}
if [ -n "${SNAP_FILE:-}" ]; then
	{
		printf 'master=%s\\n' \\
			"$(readlink /sys/class/net/$port/master 2>/dev/null | sed 's#.*/##')"
		printf 'brif_port=%s\\n' \\
			"$(bridge link show 2>/dev/null | awk -v p="$port" \\
				'$2 ~ ("^" p "@") { print $2 }')"
		printf 'operstate=%s\\n' "$(cat /sys/class/net/$port/operstate 2>/dev/null)"
	} >>"$SNAP_FILE"
fi
# Only after the port left the bridge, so the delete hits the restore path.
if [ "${DROP_BRIDGE:-0}" = 1 ] &&
	[ -z "$(readlink /sys/class/net/$port/master 2>/dev/null)" ]; then
	ip link del br0 2>/dev/null
fi
exit 1
"""

NETNS_PREFIX = "mount --make-rprivate /; mount -t sysfs sysfs /sys; "


def _write_exec(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


class Netns(unittest.TestCase):
    """Base: run shell bodies and the real harness inside one private netns."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="bridge70-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        _write_exec(self.bin / "ssh", SSH_STUB)
        _write_exec(self.bin / "ethtool", ETHTOOL_STUB)
        _write_exec(self.bin / "iperf3", IPERF3_STUB)
        _write_exec(self.bin / "iw", IW_STUB)
        if shutil.which("unshare") is None:
            self.skipTest("unshare is not installed: no private netns")
        self.require_netns()

    def netns(self, body: str, extra_env: dict | None = None,
               timeout: int = 240) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["PATH"] = "%s:%s" % (self.bin, env.get("PATH", ""))
        env.setdefault("TERM", "dumb")
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["unshare", "-Urn", "--mount", "sh", "-c", NETNS_PREFIX + body],
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )

    def require_netns(self) -> None:
        proc = self.netns("ip link add vs0 type veth peer name vs1 && "
                          "ip link del vs0")
        if proc.returncode == 0:
            return
        out = proc.stdout + proc.stderr
        if "Operation not permitted" in out or "unshare" in out.lower():
            self.skipTest("no CAP_NET_ADMIN inside unshare: %s" % out.strip())
        self.fail("netns fixture failed: %s" % out.strip())

    def bridge_port(self, port: str = "lan2") -> str:
        """master= line of `ip -j link show PORT`, empty when unbridged."""
        proc = self.netns(
            "ip -j link show %s 2>/dev/null | tr ',' '\\n' | "
            "sed -n 's/.*\"master\":\"\\([^\"]*\\)\".*/\\1/p'" % port)
        return proc.stdout.strip()

    # The veth pair the harness sees as the device data port, plus the host
    # NIC it measures against.  br0 is the bridge the base tree would call
    # br-lan; the name is deliberately different so a restore that assumes
    # br-lan cannot pass.
    NET_SETUP = textwrap.dedent(
        """\
        ip link add br0 type bridge 2>/dev/null
        ip link add lan2 type veth peer name lan2p 2>/dev/null
        ip link add vh0 type veth peer name vh0p 2>/dev/null
        ip link set lan2 master br0
        ip link set br0 up; ip link set lan2 up
        ip link set vh0 up; ip link set lan2p up
        """
    )


class LibraryDetachRestore(Netns):
    """port-detach.sh against a real bridge and a real veth pair."""

    def test_detach_leaves_the_port_up_and_out_of_brif(self) -> None:
        proc = self.netns(
            self.NET_SETUP
            + textwrap.dedent(
                """\
                . %s
                PROG=t
                pd_detach lan2; echo "detach_rc=$?"
                echo "master=$(readlink /sys/class/net/lan2/master 2>/dev/null)"
                echo "brif=$(bridge link show 2>/dev/null | awk '$2 ~ /^lan2@/ { print $2 }')"
                echo "operstate=$(cat /sys/class/net/lan2/operstate)"
                echo "carrier=$(cat /sys/class/net/lan2/carrier)"
                """
                % LIB
            )
        )
        out = proc.stdout
        self.assertEqual(proc.returncode, 0, out + proc.stderr)
        self.assertIn("detach_rc=0", out)
        self.assertIn("master=\n", out, out)
        self.assertIn("brif=\n", out, out)
        self.assertIn("operstate=up", out)
        self.assertIn("carrier=1", out)

    def test_restore_puts_the_port_back_into_the_recorded_master(self) -> None:
        proc = self.netns(
            self.NET_SETUP
            + textwrap.dedent(
                """\
                . %s
                PROG=t
                pd_detach lan2 >/dev/null 2>&1
                pd_restore; echo "restore_rc=$?"
                pd_restore; echo "second_rc=$?"
                echo "master=$(readlink /sys/class/net/lan2/master 2>/dev/null | sed 's#.*/##')"
                echo "brif=$(bridge link show 2>/dev/null | awk '$2 ~ /^lan2@/ { print $2 }')"
                """
                % LIB
            )
        )
        out = proc.stdout
        self.assertEqual(proc.returncode, 0, out + proc.stderr)
        self.assertIn("restore_rc=0", out)
        self.assertIn("second_rc=0", out)
        self.assertIn("master=br0", out)
        self.assertIn("brif=lan2@lan2p:", out)

    def test_restore_failure_is_an_error_not_a_silent_detach(self) -> None:
        proc = self.netns(
            self.NET_SETUP
            + textwrap.dedent(
                """\
                . %s
                PROG=t
                pd_detach lan2 >/dev/null 2>&1
                ip link del br0
                pd_restore; echo "restore_rc=$?"
                echo "failed=$PD_RESTORE_FAILED"
                echo "master=$(readlink /sys/class/net/lan2/master 2>/dev/null)"
                """
                % LIB
            )
        )
        out = proc.stdout
        self.assertEqual(proc.returncode, 0, out + proc.stderr)
        self.assertIn("restore_rc=1", out)
        self.assertIn("failed=1", out)
        self.assertIn("master=\n", out)
        self.assertIn("could not put lan2 back into br0", proc.stderr)
        self.assertIn("ip link set lan2 master br0", proc.stderr)

    def test_port_without_a_bridge_is_left_alone(self) -> None:
        proc = self.netns(
            self.NET_SETUP
            + textwrap.dedent(
                """\
                ip link set lan2 nomaster
                . %s
                PROG=t
                pd_detach lan2; echo "detach_rc=$?"
                echo "detached=$PD_DETACHED"
                """
                % LIB
            )
        )
        out = proc.stdout
        self.assertEqual(proc.returncode, 0, out + proc.stderr)
        self.assertIn("detach_rc=0", out)
        self.assertIn("detached=0", out)
        self.assertIn("not in a bridge", proc.stderr)


class ScriptRoundTrip(Netns):
    """The real 2.5g-wired.sh, unmodified, in the netns."""

    def run_wired(self, *extra: str, env: dict | None = None,
                  timeout: int = 240) -> subprocess.CompletedProcess:
        args = " ".join(extra)
        body = self.NET_SETUP + textwrap.dedent(
            """\
            PATH=%s:$PATH sh %s \\
                --device test@127.0.0.1 --ports lan10g \\
                --dev-lan10g-if lan2 --dev-wan10g-if wan9 \\
                --host-lan10g-if vh0 --host-wan10g-if vh0p \\
                --lan10g-dev-ip 10.44.0.1 --lan10g-host-ip 10.44.0.2 \\
                --duration 1 --parallel 1 --out-dir %s/res %s
            rc=$?
            echo "script_rc=$rc"
            echo "after_master=$(ip -j link show lan2 | tr ',' '\\n' | sed -n 's/.*"master":"\\([^"]*\\)".*/\\1/p')"
            echo "after_brif=$(bridge link show 2>/dev/null | awk '$2 ~ /^lan2@/ { print $2 }')"
            exit $rc
            """
            % (self.bin, WIRED, self.tmp, args)
        )
        return self.netns(body, env, timeout=timeout)

    def test_exit_path_restores_the_bridge_it_took_the_port_from(self) -> None:
        snap = self.tmp / "snap"
        proc = self.run_wired("--detach-port", env={"SNAP_FILE": str(snap)})
        out, err = proc.stdout, proc.stderr
        # rc=1: the arms fail (the iperf3 stub never measures), and the point
        # of this case is what the EXIT path did with the bridge anyway.
        self.assertEqual(proc.returncode, 1, out + err)

        # The detach itself, in the script's own words.
        self.assertIn("detached: lan2 is out of br0", err)
        self.assertIn("restored: lan2 is back in br0", err)

        # Mid-run: the iperf3 stub saw the port out of the bridge and still
        # up.  First record is the pre-detach probe, second the arms.
        records = []
        for block in snap.read_text(encoding="utf-8").split("master=")[1:]:
            records.append(
                dict(
                    line.split("=", 1) for line in ("master=" + block).splitlines()
                    if "=" in line
                )
            )
        self.assertGreaterEqual(len(records), 2, records)
        self.assertEqual(records[0].get("master"), "br0", records)
        self.assertTrue(records[0].get("brif_port", "").startswith("lan2@"),
                        records)
        self.assertEqual(records[-1].get("master"), "", records)
        self.assertEqual(records[-1].get("brif_port"), "", records)
        self.assertEqual(records[-1].get("operstate"), "up", records)

        # After exit, through the bridge itself: master and brif again.
        self.assertIn("script_rc=1", out, out)  # arms fail: the stub never measures
        self.assertIn("after_master=br0", out, out)
        self.assertIn("after_brif=lan2@lan2p:", out, out)

    def test_restore_that_cannot_be_verified_fails_the_run(self) -> None:
        proc = self.run_wired("--detach-port", env={"DROP_BRIDGE": "1"})
        out, err = proc.stdout, proc.stderr
        self.assertEqual(proc.returncode, 1, out + err)
        self.assertIn("script_rc=1", out, out)
        self.assertIn("status: blocked", out, out)
        self.assertIn("could not put lan2 back into br0", err)
        self.assertIn("ip link set lan2 master br0", err)
        self.assertIn("cleanup: bridge restore failed", err)
        self.assertIn("after_master=", out, out)

    def test_default_run_still_blocks_without_the_flag(self) -> None:
        proc = self.run_wired("")
        out, err = proc.stdout, proc.stderr
        self.assertEqual(proc.returncode, 0, out + err)
        self.assertIn("BLOCKED: lan2 is in br0", out, out)
        self.assertIn("ip link set lan2 nomaster", out)
        self.assertIn("after_master=br0", out, out)
        # The record hw-gap-report.sh reads is unchanged: a bridged port
        # without the flag is still a configuration block, not a new status.
        record = json.loads((self.tmp / "res" / "result.json").read_text())
        self.assertEqual(record["status"], "blocked")
        self.assertEqual(record["missing"], "port-in-bridge")


class DryRunPrintsTheCommands(Netns):
    """--dry-run must print the detach and the restore, and run neither."""

    def test_wired_dry_run_prints_both_ip_link_set_lines(self) -> None:
        # No netdev needed: --dry-run runs no SSH and touches nothing.
        proc = self.netns(
            "sh %s --dry-run --detach-port --ports lan10g --dev-lan10g-if lan2"
            % WIRED)
        out = proc.stdout
        self.assertEqual(proc.returncode, 0, out + proc.stderr)
        self.assertIn('ip link set lan2 nomaster', out)
        self.assertIn('ip link set lan2 master ORIG_MASTER', out)
        self.assertIn("planned, not run", out)

    def test_wired_dry_run_without_the_flag_prints_no_detach(self) -> None:
        proc = self.netns(
            "sh %s --dry-run --ports lan10g --dev-lan10g-if lan2" % WIRED)
        out = proc.stdout
        self.assertEqual(proc.returncode, 0, out + proc.stderr)
        self.assertNotIn("nomaster", out)

    def test_bpath_dry_run_prints_both_ip_link_set_lines(self) -> None:
        proc = self.netns(
            self.NET_SETUP + textwrap.dedent(
                """\
                PATH=%s:$PATH sh %s --dry-run --detach-port \\
                    --device test@127.0.0.1 --feeder-iface vh0
                """
                % (self.bin, BPATH)
            )
        )
        out = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, out)
        self.assertIn('ip link set lan10g nomaster', out)
        self.assertIn('ip link set lan10g master ORIG_MASTER', out)

    def test_bpath_dry_run_without_the_flag_prints_no_detach(self) -> None:
        proc = self.netns(
            self.NET_SETUP + textwrap.dedent(
                """\
                PATH=%s:$PATH sh %s --dry-run \\
                    --device test@127.0.0.1 --feeder-iface vh0
                """
                % (self.bin, BPATH)
            )
        )
        out = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, out)
        self.assertNotIn("nomaster", out)


class BpathRestoresToo(Netns):
    """b-path-25g.sh --detach-port: detach for the arms, restore on exit."""

    def test_bpath_takes_the_port_out_and_puts_it_back(self) -> None:
        # b-path needs a SIGINT-free path: a feeder that answers iperf3 is not
        # needed, because the run stops at the first failing arm and the EXIT
        # trap is what this case is about.
        proc = self.netns(
            textwrap.dedent(
                """\
                ip link add br0 type bridge 2>/dev/null
                ip link add lan10g type veth peer name lan10gp 2>/dev/null
                ip link add vh0 type veth peer name vh0p 2>/dev/null
                ip link set lan10g master br0
                ip link set br0 up; ip link set lan10g up; ip link set vh0 up
                # A real neighbor entry so the client-MAC lookup on the "AP"
                # succeeds and the run gets as far as the detach.
                ip neigh add 10.0.0.9 lladdr 02:00:00:00:00:09 dev lan10g
                PATH=%s:$PATH timeout 90 sh %s --run --detach-port \\
                    --device test@127.0.0.1 --feeder-iface vh0 \\
                    --client 10.0.0.9 --client-mac 02:00:00:00:00:09 \\
                    --ap-iface wlan0 --duration 1 --interval 1 \\
                    --out-dir %s/res
                echo "script_rc=$?"
                echo "after_master=$(ip -j link show lan10g | tr ',' '\\n' | sed -n 's/.*"master":"\\([^"]*\\)".*/\\1/p')"
                """
                % (self.bin, BPATH, self.tmp)
            ),
            timeout=180,
        )
        out, err = proc.stdout, proc.stderr
        self.assertEqual(proc.returncode, 0, out + err)
        self.assertIn("detach: lan10g is in br0", err)
        self.assertIn("detached: lan10g is out of br0", err)
        self.assertIn("restore: ip link set lan10g master br0", err)
        self.assertIn("restored: lan10g is back in br0", err)
        self.assertIn("after_master=br0", out, out)


if __name__ == "__main__":
    unittest.main()
