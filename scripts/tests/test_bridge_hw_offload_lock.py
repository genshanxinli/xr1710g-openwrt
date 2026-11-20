#!/usr/bin/env python3
"""Guard the bridge-hw-offload reload window (issue #5).

Two hotplug scripts share /var/lock/bridge-hw-offload.lock:

  hotplug.d/iface/51-bridge-hw-offload  holds it for the whole settle loop
      (BR_HW_SETTLE_TIMEOUT, default 120 s) plus the recheck sleep
      (RECHECK_DELAY, default 40 s) -- up to 160 s.
  hotplug.d/net/50-bridge-hw-offload    waits on it with `flock -w N`.

If N is shorter than the iface script's critical section, every member
change that overlaps the settle loop is dropped instead of queued.  That
is what was measured on r38047: 54 consecutive "reload already in progress,
giving up" lines in logread and 0 successful reloads, so the live
`table bridge fw4` kept a device list that predated the wlan vifs being
re-created.  The original value was 10 s.

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
NET_SCRIPT = os.path.join(
    REPO, "target/linux/airoha/an7581/base-files/etc/hotplug.d/net/50-bridge-hw-offload"
)
IFACE_SCRIPT = os.path.join(
    REPO, "target/linux/airoha/an7581/base-files/etc/hotplug.d/iface/51-bridge-hw-offload"
)
LOCK = "/var/lock/bridge-hw-offload.lock"


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def net_lock_wait():
    match = re.search(r"flock\s+-w\s+(\d+)\s+9", read(NET_SCRIPT))
    assert match, "50-bridge-hw-offload no longer takes the lock with flock -w N"
    return int(match.group(1))


def iface_hold_seconds():
    text = read(IFACE_SCRIPT)
    settle = re.search(r"BR_HW_SETTLE_TIMEOUT:-(\d+)", text)
    recheck = re.search(r"RECHECK_DELAY:-(\d+)", text)
    assert settle and recheck, "51-bridge-hw-offload lost its settle/recheck defaults"
    return int(settle.group(1)) + int(recheck.group(1))


class StaticWindow(unittest.TestCase):
    def test_wait_outlives_the_settle_loop(self):
        wait, hold = net_lock_wait(), iface_hold_seconds()
        self.assertGreaterEqual(
            wait,
            hold,
            f"50-bridge-hw-offload waits {wait}s but 51 holds the lock for {hold}s; "
            "member changes would be dropped instead of queued",
        )


class QueuesInsteadOfDropping(unittest.TestCase):
    """The 10 s form is red here: the holder keeps the lock for 12 s."""

    HOLD = 12

    def test_reload_runs_after_a_long_holder(self):
        with tempfile.TemporaryDirectory() as tmp:
            net = os.path.join(tmp, "sys", "class", "net")
            dev = os.path.join(net, "phy0.9-ap0")
            os.makedirs(os.path.join(dev))
            os.makedirs(os.path.join(tmp, "virtual", "net"))
            os.symlink(
                "../../../../virtual/net/br-lan",
                os.path.join(dev, "master"),
            )
            record = os.path.join(tmp, "reloads")
            # A path with no spaces, so the script's unquoted $BR_HW_RELOAD
            # word-splits into one word.
            recorder = os.path.join(tmp, "record-reload")
            with open(recorder, "w", encoding="utf-8") as fh:
                fh.write(f'#!/bin/sh\necho queued >> "{record}"\n')
            os.chmod(recorder, 0o755)

            holder = subprocess.Popen(
                ["flock", "-x", LOCK, "-c", f"sleep {self.HOLD}"], start_new_session=True
            )
            try:
                time.sleep(0.5)  # let the holder take the lock first
                env = dict(
                    os.environ,
                    ACTION="add",
                    DEVICENAME="phy0.9-ap0",
                    BR_HW_SYS_NET=net,
                    BR_HW_BRIDGE="br-lan",
                    BR_HW_RELOAD=recorder,
                )
                subprocess.run(["sh", NET_SCRIPT], env=env, check=True, timeout=30)

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
