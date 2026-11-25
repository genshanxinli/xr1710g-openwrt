#!/usr/bin/env python3
"""Guard the bridge-hw-offload reload window (issue #5).

Two hotplug scripts share /var/lock/bridge-hw-offload.lock:

  hotplug.d/iface/51-bridge-hw-offload  holds it for the whole settle loop
      (BR_HW_SETTLE_TIMEOUT, default 120 s) plus the recheck sleep
      (RECHECK_DELAY, default 40 s) -- up to 160 s.
  hotplug.d/net/50-bridge-hw-offload    waits on it with a bounded retry loop
      on `flock -n` -- N one-second attempts, because busybox's flock (the only
      flock the image has) rejects `-w`.

If N is shorter than the iface script's critical section, every member
change that overlaps the settle loop is dropped instead of queued.  That
is what was measured on r38047: 54 consecutive "reload already in progress,
giving up" lines in logread and 0 successful reloads, so the live
`table bridge fw4` kept a device list that predated the wlan vifs being
re-created.  The original value was 10 s.

`50-bridge-hw-offload` honours BRIDGE_HW_OFFLOAD_LOCK so this suite can put
the lock in a temp dir: hosts whose /var/lock is read-only would otherwise
fail here for a host reason, not a product one.  The live default stays
/var/lock/bridge-hw-offload.lock.

Run: python3 scripts/tests/test_bridge_hw_offload_lock.py
"""

import os
import re
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NET_SCRIPT = os.environ.get(
    "BRIDGE_HW_OFFLOAD_UNDER_TEST",
    os.path.join(
        REPO, "target/linux/airoha/an7581/base-files/etc/hotplug.d/net/50-bridge-hw-offload"
    ),
)
IFACE_SCRIPT = os.path.join(
    REPO, "target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/51-bridge-hw-offload"
)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def net_lock_wait():
    # A retry loop, not `flock -w N`: busybox's flock has no -w.  The bound is
    # the retry count, one second per try.
    match = re.search(r'\[ "\$waits" -lt (\d+) \]', read(NET_SCRIPT))
    assert match, "50-bridge-hw-offload no longer bounds its flock -n retry loop"
    return int(match.group(1))


def iface_hold_seconds():
    text = read(IFACE_SCRIPT)
    settle = re.search(r"BR_HW_SETTLE_TIMEOUT:-(\d+)", text)
    recheck = re.search(r"RECHECK_DELAY:-(\d+)", text)
    assert settle and recheck, "51-bridge-hw-offload lost its settle/recheck defaults"
    return int(settle.group(1)) + int(recheck.group(1))


def fixture(tmp):
    """A member-add hotplug event: the netdev sits under br-lan."""
    net = os.path.join(tmp, "sys", "class", "net")
    dev = os.path.join(net, "phy0.9-ap0")
    os.makedirs(dev)
    os.makedirs(os.path.join(tmp, "virtual", "net"))
    os.symlink("../../../../virtual/net/br-lan", os.path.join(dev, "master"))
    record = os.path.join(tmp, "reloads")
    # A path with no spaces, so the script's unquoted $BR_HW_RELOAD
    # word-splits into one word.
    recorder = os.path.join(tmp, "record-reload")
    with open(recorder, "w", encoding="utf-8") as fh:
        fh.write(f'#!/bin/sh\necho queued >> "{record}"\n')
    os.chmod(recorder, 0o755)
    return net, recorder, record


def hotplug_env(net, recorder, lock):
    return dict(
        os.environ,
        ACTION="add",
        DEVICENAME="phy0.9-ap0",
        BR_HW_SYS_NET=net,
        BR_HW_BRIDGE="br-lan",
        BR_HW_RELOAD=recorder,
        BRIDGE_HW_OFFLOAD_LOCK=lock,
    )


def wait_for(path, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.1)
    return os.path.exists(path)


class StaticWindow(unittest.TestCase):
    def test_wait_outlives_the_settle_loop(self):
        wait, hold = net_lock_wait(), iface_hold_seconds()
        self.assertGreaterEqual(
            wait,
            hold,
            f"50-bridge-hw-offload waits {wait}s but 51 holds the lock for {hold}s; "
            "member changes would be dropped instead of queued",
        )

    def test_the_live_default_lock_is_unchanged(self):
        text = read(NET_SCRIPT)
        self.assertIn(
            "${BRIDGE_HW_OFFLOAD_LOCK:-/var/lock/bridge-hw-offload.lock}",
            text,
            "the live default lock path moved; 51-bridge-hw-offload shares it",
        )
        self.assertIn('exec 9>"$LOCK_FILE"', text)


class LockPathOverride(unittest.TestCase):
    """A read-only /var/lock must not decide whether the suite is green."""

    def test_override_moves_the_lock_out_of_var_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            net, recorder, record = fixture(tmp)
            lock = os.path.join(tmp, "lockdir", "bridge-hw-offload.lock")
            subprocess.run(
                ["sh", NET_SCRIPT],
                env=hotplug_env(net, recorder, lock),
                check=True,
                timeout=30,
            )
            self.assertTrue(
                wait_for(lock, 5),
                "BRIDGE_HW_OFFLOAD_LOCK was ignored: the script never opened "
                f"{lock}, it still uses the hardcoded default",
            )
            self.assertTrue(
                wait_for(record, 10),
                "reload never ran after the overridden lock was taken",
            )

    def test_bare_filename_lock_without_slash_does_not_create_directory(self):
        # When LOCK_FILE has no '/', "${LOCK_FILE%/*}" equals "$LOCK_FILE"; an
        # unguarded `mkdir -p` turns the lock file itself into a directory and
        # `exec 9>"$LOCK_FILE"` fails with EISDIR.
        with tempfile.TemporaryDirectory() as tmp:
            net, recorder, record = fixture(tmp)
            lock_name = "bridge-hw-offload.lock"
            lock_path = os.path.join(tmp, lock_name)
            subprocess.run(
                ["sh", NET_SCRIPT],
                cwd=tmp,
                env=hotplug_env(net, recorder, lock_name),
                check=True,
                timeout=30,
            )
            self.assertTrue(
                wait_for(lock_path, 5),
                f"script never created bare lock {lock_path}",
            )
            self.assertFalse(
                os.path.isdir(lock_path),
                f"mkdir -p turned bare LOCK_FILE {lock_path} into a directory",
            )
            self.assertTrue(
                wait_for(record, 10),
                "reload never ran with a bare-filename LOCK_FILE",
            )


class QueuesInsteadOfDropping(unittest.TestCase):
    """The 10 s form is red here: the holder keeps the lock for 12 s."""

    HOLD = 12

    def test_reload_runs_after_a_long_holder(self):
        with tempfile.TemporaryDirectory() as tmp:
            net, recorder, record = fixture(tmp)
            lockdir = os.path.join(tmp, "lockdir")
            os.makedirs(lockdir)
            lock = os.path.join(lockdir, "bridge-hw-offload.lock")
            holder = subprocess.Popen(
                ["flock", "-x", lock, "-c", f"sleep {self.HOLD}"], start_new_session=True
            )
            try:
                time.sleep(0.5)  # let the holder take the lock first
                subprocess.run(
                    ["sh", NET_SCRIPT],
                    env=hotplug_env(net, recorder, lock),
                    check=True,
                    timeout=30,
                )

                deadline = time.time() + net_lock_wait() + 5
                while time.time() < deadline:
                    if os.path.exists(record):
                        break
                    time.sleep(0.5)
                self.assertTrue(
                    os.path.exists(record),
                    f"reload never ran within {net_lock_wait()}s of a {self.HOLD}s holder",
                )
            finally:
                holder.terminate()
                holder.wait(timeout=10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
