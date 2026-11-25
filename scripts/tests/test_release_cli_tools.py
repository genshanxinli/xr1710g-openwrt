#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Pin the release image's required CLI providers to the device template.

The image gate (``scripts/check-release-image-features.py``) can only see what
the build produced.  This test fails when the device template stops selecting a
provider, when the gate's package table drifts from this one, or when the
``bridge`` consumers disappear; it runs in the Python suite on every PR.

What is pinned, and why:

  * ``bridge`` is executed on the device by the flowsense rpcd backend
    (``luci.airoha_flowsense.uc``: ``popen('bridge fdb show ...')``) and by
    ``scripts/wireless/lib/port-detach.sh`` (``bridge fdb show br ...``), so
    ``ip-bridge`` must be in the device template *and* in the package's own
    dependency list (installing flowsense alone must also get ``bridge``).
  * ``base64`` is the console file-transfer primitive (issue #375).  That
    field note is not tracked, and the tree has no script consumer, so only
    the package selection is pinned here -- no fake caller assertion.

Both providers are packages, not BusyBox applets: ``DEVICE_PACKAGES`` is the
only per-device hook the repository can review, and the release manifest can
prove a package but not an applet.

Red half (before ``ip-bridge``/``coreutils-base64`` were added):

    python3 -m unittest scripts.tests.test_release_cli_tools -v
    # FAIL: test_device_template_pins_both_providers
    #       DEVICE_PACKAGES lacks ['coreutils-base64', 'ip-bridge']
    # FAIL: test_flowsense_declares_bridge_dependency
    #       '+ip-bridge' not found in the flowsense Makefile
    # FAIL: test_gate_table_matches_the_pin
    #       AttributeError: module has no attribute 'REQUIRED_CLI_TOOLS'
    # ok:   test_bridge_consumers_are_real
"""

from __future__ import annotations

import importlib.util
import os
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
AN7581_MK = Path(
    os.environ.get("AN7581_MK_UNDER_TEST", REPO / "target/linux/airoha/image/an7581.mk")
)
GATE = Path(
    os.environ.get(
        "CHECK_RELEASE_IMAGE_FEATURES_UNDER_TEST",
        REPO / "scripts/check-release-image-features.py",
    )
)
FLOWSENSE_MK = Path(
    os.environ.get(
        "FLOWSENSE_MK_UNDER_TEST",
        REPO / "package/luci-app-airoha-flowsense/Makefile",
    )
)
UCODE = Path(
    os.environ.get(
        "FLOWSENSE_UCODE_UNDER_TEST",
        REPO / "package/luci-app-airoha-flowsense/root/usr/share/rpcd/ucode/luci.airoha_flowsense.uc",
    )
)
PORT_DETACH = Path(
    os.environ.get(
        "PORT_DETACH_UNDER_TEST", REPO / "scripts/wireless/lib/port-detach.sh"
    )
)

# package -> path in the release rootfs.  The gate keeps its own copy so that a
# drift between the two is a failure instead of a silent narrowing.
REQUIRED = {"ip-bridge": "/usr/sbin/bridge", "coreutils-base64": "/bin/base64"}


def _block(text: str, name: str) -> str:
    match = re.search(rf"define Device/{re.escape(name)}\n(.*?)\nendef", text, re.S)
    return match.group(1) if match else ""


def _packages(block: str) -> set[str]:
    joined = re.sub(r"\\\n", " ", block)
    match = re.search(r"DEVICE_PACKAGES\s*(?::=|\+=|=)\s*(.*)", joined)
    return set(match.group(1).split()) if match else set()


def device_packages() -> set[str]:
    """Packages of the XR1710G image: common block plus its own block only.

    Deliberately not a union over every ``Device/gemtek*``: a package added to
    W1700K must not mask its removal from XR1710G.
    """
    text = AN7581_MK.read_text(encoding="utf-8")
    return _packages(_block(text, "gemtek-ubi-common")) | _packages(
        _block(text, "gemtek_xr1710g-ubi")
    )


class RequiredCliTools(unittest.TestCase):
    def test_device_template_pins_both_providers(self) -> None:
        missing = set(REQUIRED) - device_packages()
        self.assertFalse(missing, f"DEVICE_PACKAGES lacks {sorted(missing)}")

    def test_gate_table_matches_the_pin(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "check_release_image_features", GATE
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.REQUIRED_CLI_TOOLS, REQUIRED)

    def test_flowsense_declares_bridge_dependency(self) -> None:
        self.assertIn("+ip-bridge", FLOWSENSE_MK.read_text(encoding="utf-8"))

    def test_bridge_consumers_are_real(self) -> None:
        # A bare "bridge" would match the unrelated comment at ucode:197.
        self.assertIn("popen('bridge fdb show", UCODE.read_text(encoding="utf-8"))
        self.assertIn("bridge fdb show", PORT_DETACH.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
