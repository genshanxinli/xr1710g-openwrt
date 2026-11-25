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
        self.assertEqual(proc.returncode, 2, out + err)
        self.assertIn("BLOCKED: lan2 is in br0", out, out)
        self.assertIn("ip link set lan2 nomaster", out)
        self.assertIn("after_master=br0", out, out)
        # The record hw-gap-report.sh reads is unchanged: a bridged port
        # without the flag is still a configuration block, not a new status.
        record = json.loads(
            (self.tmp / "res" / "no-hardware" / "result.json").read_text())
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


class DetachFailureStillRestores(unittest.TestCase):
    """A failing `ip link set ... nomaster` must not claim the port is untouched.

    The remote call can fail after the link was already taken out of the
    bridge (SSH drops, the device reboots mid-command, `ip` reports an error
    after the netlink change landed).  `pd_detach` used to set PD_DETACHED=1
    only *after* a successful call, so that path returned 1 with the flag at
    0 and `pd_restore` short-circuited: the port stayed out of br-lan until
    a reboot.  Deterministic stub, no netns: PD_EXEC answers the probe and
    fails the nomaster call, and the test records whether the restore ran.
    """

    def run_library(
        self,
        *,
        detach_lands: bool = True,
        master_delay: int = 0,
        brif_present_after_restore: bool = True,
        fail_master_cmd: bool = False,
    ) -> subprocess.CompletedProcess:
        self.tmp = Path(tempfile.mkdtemp(prefix="port-detach-fail."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        state = self.tmp / "master.state"
        state.write_text("br0\n", encoding="utf-8")
        probe_count = self.tmp / "probe.count"
        probe_count.write_text("0\n", encoding="utf-8")
        fake = self.tmp / "fake-exec"
        _write_exec(
            fake,
            textwrap.dedent(
                """\
                #!/bin/sh
                case $1 in
                *"ip link set lan2 nomaster"*)
                    if [ "${DETACH_LANDS:-1}" = 1 ]; then
                        : >"${STATE_FILE:?}"
                    fi
                    printf 'fake: RTNETLINK answers: Link has been severed\\n' >&2
                    exit 1
                    ;;
                *"ip link set lan2 master br0"*)
                    printf '%s\\n' "$1" >>"${RESTORE_LOG:?}"
                    if [ "${FAIL_MASTER_CMD:-0}" = 1 ]; then
                        exit 1
                    fi
                    printf 'br0\\n' >"${STATE_FILE:?}"
                    printf '0\\n' >"${PROBE_COUNT:?}"
                    exit 0
                    ;;
                *class/net/lan2*)
                    m=$(cat "${STATE_FILE:?}" 2>/dev/null)
                    if [ -n "$m" ] && [ "${MASTER_DELAY:-0}" -gt 0 ] && [ -f "${RESTORE_LOG:?}" ]; then
                        n=$(cat "${PROBE_COUNT:?}" 2>/dev/null || echo 0)
                        n=$((n + 1))
                        printf '%s\\n' "$n" >"${PROBE_COUNT:?}"
                        if [ "$n" -le "$MASTER_DELAY" ]; then
                            m=
                        fi
                    fi
                    printf 'master=%s\\noperstate=up\\nspeed=2500\\ncarrier=1\\n' "$m"
                    ;;
                *"test -e"*brif/lan2*)
                    m=$(cat "${STATE_FILE:?}" 2>/dev/null)
                    if [ "$m" = br0 ] && { [ ! -f "${RESTORE_LOG:?}" ] || [ "${BRIF_AFTER:-1}" = 1 ]; }; then
                        exit 0
                    fi
                    exit 1
                    ;;
                esac
                exit 0
                """
            ),
        )
        env = dict(os.environ)
        env["PD_EXEC"] = str(fake)
        env["STATE_FILE"] = str(state)
        env["PROBE_COUNT"] = str(probe_count)
        env["RESTORE_LOG"] = str(self.tmp / "restore.log")
        env["DETACH_LANDS"] = "1" if detach_lands else "0"
        env["MASTER_DELAY"] = str(master_delay)
        env["BRIF_AFTER"] = "1" if brif_present_after_restore else "0"
        env["FAIL_MASTER_CMD"] = "1" if fail_master_cmd else "0"
        env["PROG"] = "t"
        body = textwrap.dedent(
            """\
            . %s
            pd_detach lan2; echo "detach_rc=$?"
            echo "detached_after_detach=$PD_DETACHED"
            pd_restore; echo "restore_rc=$?"
            echo "detached_after_restore=$PD_DETACHED"
            echo "restore_failed=$PD_RESTORE_FAILED"
            """
            % LIB
        )
        return subprocess.run(
            ["sh", "-c", body],
            capture_output=True,
            text=True,
            timeout=60,
            env=env,
            check=False,
        )

    def test_a_failed_nomaster_still_arms_the_restore(self) -> None:
        proc = self.run_library(detach_lands=True)
        out, err = proc.stdout, proc.stderr
        self.assertIn("detach_rc=1", out, out + err)
        self.assertIn("detached_after_detach=1", out, out + err)
        self.assertIn("state is unknown", err)
        self.assertIn("restore_rc=0", out, out + err)
        self.assertIn("detached_after_restore=0", out, out + err)
        self.assertIn("restored: lan2 is back in br0", err)
        log = self.tmp / "restore.log"
        self.assertEqual(
            log.read_text().splitlines(), ["ip link set lan2 master br0"]
        )

    def test_restore_is_idempotent_when_port_never_left_master(self) -> None:
        proc = self.run_library(detach_lands=False, fail_master_cmd=True)
        out, err = proc.stdout, proc.stderr
        self.assertIn("detach_rc=1", out, out + err)
        self.assertIn("restore_rc=0", out, out + err)
        self.assertIn("detached_after_restore=0", out, out + err)
        log = self.tmp / "restore.log"
        self.assertFalse(
            log.exists(),
            "pd_restore must probe master first and skip re-enslaving: %s" % err,
        )

    def test_restore_polls_master_and_requires_brif_presence(self) -> None:
        # Delayed master settle: 2 empty probes before master reads br0.
        proc = self.run_library(detach_lands=True, master_delay=2)
        out, err = proc.stdout, proc.stderr
        self.assertIn("restore_rc=0", out, out + err)
        self.assertIn("detached_after_restore=0", out, out + err)

        # Master settles, but brif/lan2 never appears: restore must fail.
        proc2 = self.run_library(
            detach_lands=True, brif_present_after_restore=False
        )
        out2, err2 = proc2.stdout, proc2.stderr
        self.assertIn("restore_rc=1", out2, out2 + err2)
        self.assertIn("restore_failed=1", out2, out2 + err2)

    def test_ssh_ingress_port_accepts_ipv6_and_scopes_neigh_to_bridge(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="port-detach-v6."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bindir = self.tmp / "bin"
        bindir.mkdir()
        neigh_log = self.tmp / "neigh.log"
        _write_exec(
            bindir / "ip",
            textwrap.dedent(
                """\
                #!/bin/sh
                printf '%s\\n' "$*" >>"${NEIGH_LOG:?}"
                case "$*" in
                "neigh show fd00::1234 dev br-lan"|"neigh show fe80::1 dev br-lan")
                    printf '%s lladdr aa:bb:cc:dd:ee:ff REACHABLE\\n' "$3"
                    ;;
                esac
                exit 0
                """
            ),
        )
        _write_exec(
            bindir / "bridge",
            textwrap.dedent(
                """\
                #!/bin/sh
                case "$*" in
                "fdb show br br-lan")
                    printf 'aa:bb:cc:dd:ee:ff dev lan3 master br-lan\\n'
                    ;;
                esac
                exit 0
                """
            ),
        )
        for ssh_client, expected_ip in (
            ("fd00::1234 54321 22", "fd00::1234"),
            ("fe80::1%br-lan 54321 22", "fe80::1"),
        ):
            with self.subTest(ssh_client=ssh_client):
                if neigh_log.exists():
                    neigh_log.unlink()
                env = dict(
                    os.environ,
                    PATH="%s:%s" % (bindir, os.environ.get("PATH", "/usr/bin:/bin")),
                    SSH_CLIENT=ssh_client,
                    NEIGH_LOG=str(neigh_log),
                )
                env.pop("PD_EXEC", None)
                proc = subprocess.run(
                    ["sh", "-c", '. "$1"; pd_ssh_ingress_port br-lan', "v6", str(LIB)],
                    capture_output=True,
                    text=True,
                    timeout=60,
                    env=env,
                    check=False,
                )
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(proc.stdout.strip(), "lan3", proc.stdout + proc.stderr)
                self.assertTrue(neigh_log.is_file(), "ip neigh show was never called")
                self.assertIn(
                    "neigh show %s dev br-lan" % expected_ip,
                    neigh_log.read_text(encoding="utf-8"),
                )


class BpathSpeedGateAndBusyboxTr(unittest.TestCase):
    """b-path-25g.sh accepts >= 2500 Mb/s (5G/10G) and uses BusyBox-safe tr."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="bpath-speed."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()

    def test_bpath_accepts_10g_feeder_and_uses_literal_tr_ranges(self) -> None:
        text = BPATH.read_text(encoding="utf-8")
        self.assertNotIn("[:upper:]", text)
        self.assertNotIn("[:lower:]", text)
        _write_exec(
            self.bin / "ethtool",
            textwrap.dedent(
                """\
                #!/bin/sh
                case "$1" in
                -i) printf 'driver: stub10g\\n'; exit 0 ;;
                esac
                printf 'Settings for %s:\\n\\tSpeed: %sMb/s\\n\\tDuplex: Full\\n\\tLink detected: yes\\n' \
                    "$1" "${STUB_SPEED:-10000}"
                """
            ),
        )
        _write_exec(
            self.bin / "ip",
            textwrap.dedent(
                """\
                #!/bin/sh
                case "$*" in
                *"link show dev eth10g"*) exit 0 ;;
                *"route get"*) printf '192.0.2.1 dev mgmt0\\n'; exit 0 ;;
                *"route show default"*) printf 'default dev mgmt0\\n'; exit 0 ;;
                *"-o link show"*) printf '1: lo: <LOOPBACK>\\n2: mgmt0: <UP>\\n3: eth10g: <UP>\\n'; exit 0 ;;
                esac
                exit 0
                """
            ),
        )
        env = dict(
            os.environ,
            PATH="%s:%s" % (self.bin, os.environ.get("PATH", "/usr/bin:/bin")),
            STUB_SPEED="10000",
        )
        proc = subprocess.run(
            ["sh", str(BPATH), "--dry-run", "--device", "root@192.0.2.1",
             "--feeder-iface", "eth10g"],
            capture_output=True,
            text=True,
            timeout=60,
            env=env,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("feeder: eth10g link=10000Mb/s", proc.stdout)
        self.assertIn(">= 2500, accepted", proc.stderr)
        # Auto-discovery must also pick a 10G NIC and keep speed=10000 (not 2500).
        proc_auto = subprocess.run(
            ["sh", str(BPATH), "--dry-run", "--device", "root@192.0.2.1"],
            capture_output=True,
            text=True,
            timeout=60,
            env=env,
            check=False,
        )
        self.assertEqual(proc_auto.returncode, 0, proc_auto.stdout + proc_auto.stderr)
        self.assertIn("feeder: eth10g link=10000Mb/s", proc_auto.stdout)


if __name__ == "__main__":
    unittest.main()
