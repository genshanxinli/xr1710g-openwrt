#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Pin the U-Boot env size contract on the airoha UBI boards (#386).

``fw_env.config`` describes the *Linux* view of the U-Boot environment.  Its
third column (``envsize``) must equal the ``CONFIG_ENV_SIZE`` the board's
U-Boot was built with, because both sides checksum ``envsize - 5`` bytes:

* U-Boot: ``ENV_SIZE = CONFIG_ENV_SIZE - ENV_HEADER_SIZE`` (5 with redundancy).
* fw_env: ``CUR_ENVSIZE - sizeof(uint32_t) - sizeof(char)``.

A mismatch is not a boot failure, it is worse: ``fw_setenv`` reports success,
writes a blob U-Boot cannot read, and the next boot silently falls back to the
default environment.  The pre-#386 helper hard-coded one LEB (``0x1f000``) for
every UBI board while the Gemtek defconfigs use ``0x4000``.

This test parses the expected size from the U-Boot patches, drives the real
``uboot-envtools.sh`` helper and the real ``airoha_an7581`` uci-defaults
script in a throwaway root, and asserts the generated ``fw_env.config`` third
column.  The board script is also checked for the upgrade migration: both
``/etc/config/ubootenv`` and ``/etc/fw_env.config`` are conffiles, so fixing
the helper only helps fresh installs.

Point ``UBOOT_ENVTOOLS_SH_UNDER_TEST`` / ``AIROHA_AN7581_UNDER_TEST`` at older
copies to reproduce the red half without touching the tree.

Run from the repository root:

    python3 scripts/tests/test_uboot_env_size_contract.py
"""

import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / "package/boot/uboot-tools/uboot-envtools/files/uboot-envtools.sh"
BOARD = REPO / "package/boot/uboot-tools/uboot-envtools/files/airoha_an7581"
PATCH_XR = REPO / "package/boot/uboot-airoha/patches/999-airoha-add-gemtek-xr1710g.patch"
PATCH_W1700K = REPO / "package/boot/uboot-airoha/patches/999-airoha-add-gemtek-w1700k.patch"
PATCH_NOKIA = REPO / "package/boot/uboot-airoha/patches/401-add-nokia-xg-040g-md.patch"

XR_DEFCONFIG = "configs/an7581_xr1710g_defconfig"
W1700K_DEFCONFIG = "configs/an7581_w1700k_defconfig"
NOKIA_DEFCONFIG = "configs/an7581_nokia_xg-040g-md_defconfig"

# U-Boot env/Kconfig: "default 0x1f000" for ENV_SIZE.  The Nokia defconfig
# relies on that default; if it ever gains an explicit CONFIG_ENV_SIZE the
# parsing test below turns red and this constant must go away.
KCONFIG_ENV_SIZE_DEFAULT = "0x1f000"
LEB_SIZE = "0x1f000"

BOARD_CASES = (
    ("gemtek,xr1710g-ubi", PATCH_XR, XR_DEFCONFIG),
    ("gemtek,w1700k-ubi", PATCH_W1700K, W1700K_DEFCONFIG),
    ("nokia,xg-040g-md-ubi", PATCH_NOKIA, NOKIA_DEFCONFIG),
)


def patch_added_lines(patch, target):
    """Lines added by the patch hunk that creates ``b/<target>``.

    Patches refreshed with quilt may lack the ``diff --git`` header, so the
    file boundary is taken from ``+++ b/<path>`` itself.
    """
    lines = []
    inside = False
    for raw in patch.read_text(encoding="utf-8").splitlines():
        if raw.startswith("+++ "):
            inside = raw[4:].strip() == "b/" + target
            continue
        if raw.startswith("--- ") or raw.startswith("diff --git "):
            inside = False
            continue
        if inside and raw.startswith("+") and not raw.startswith("+++"):
            lines.append(raw[1:])
    return lines


def defconfig_env_size(patch, target):
    for line in patch_added_lines(patch, target):
        if line.startswith("CONFIG_ENV_SIZE="):
            return line.split("=", 1)[1].strip()
    return None


def u_boot_env_size(board):
    for name, patch, defconfig in BOARD_CASES:
        if name != board:
            continue
        value = defconfig_env_size(patch, defconfig)
        if value is not None:
            return value
        if board == "nokia,xg-040g-md-ubi":
            return KCONFIG_ENV_SIZE_DEFAULT
        raise AssertionError(f"{defconfig} has no CONFIG_ENV_SIZE")
    raise AssertionError(f"unknown board {board}")


def helper_path():
    return Path(os.environ.get("UBOOT_ENVTOOLS_SH_UNDER_TEST") or HELPER)


def board_path():
    return Path(os.environ.get("AIROHA_AN7581_UNDER_TEST") or BOARD)


# A minimal uci(1) that keeps its state in JSON.  Only the commands the
# uboot-envtools scripts use are implemented: batch, set, get, commit, count.
UCI_STUB = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json
    import os
    import re
    import sys

    STATE = os.environ["TEST_UCI_STATE"]
    PATH_RE = re.compile(
        r"^([A-Za-z0-9_-]+)\\.(?:@([A-Za-z0-9_-]+)\\[(-?\\d+)\\]|([A-Za-z0-9_]+))\\.(.+)$"
    )


    def load():
        try:
            with open(STATE, encoding="utf-8") as handle:
                return json.load(handle)
        except FileNotFoundError:
            return {}


    def save(data):
        with open(STATE, "w", encoding="utf-8") as handle:
            json.dump(data, handle)


    def locate(data, path):
        match = PATH_RE.match(path)
        if not match:
            return None
        package, section_type, index, name, option = match.groups()
        if section_type is not None:
            sections = [
                section
                for section in data.get(package, [])
                if section.get("type") == section_type
            ]
            try:
                section = sections[int(index)]
            except IndexError:
                return None
        else:
            section = next(
                (
                    section
                    for section in data.get(package, [])
                    if section.get("name") == name
                ),
                None,
            )
            if section is None:
                return None
        return section.setdefault("options", {}), option


    def apply(data, line):
        # uci batch uses "<path>=<value>" for set, so accept both spellings.
        line = line.strip()
        if not line:
            return
        if line.startswith("add "):
            _, package, section_type = line.split()
            data.setdefault(package, []).append(
                {"type": section_type, "name": None, "options": {}}
            )
            return
        if line.startswith("set "):
            line = line[4:]
        path, sep, value = line.partition("=")
        if not sep:
            raise SystemExit("unsupported batch command: " + line)
        found = locate(data, path.strip())
        if found is None:
            raise SystemExit("no such section: " + path)
        found[0][found[1]] = value.strip().strip("'")


    def main(argv):
        args = list(argv)
        while args and args[0].startswith("-"):
            args.pop(0)
        if not args:
            return 1
        command, rest = args[0], args[1:]
        data = load()
        if command == "batch":
            for line in sys.stdin:
                apply(data, line)
            save(data)
            return 0
        if command == "set":
            apply(data, rest[0])
            save(data)
            return 0
        if command == "commit":
            save(data)
            return 0
        if command == "get":
            found = locate(data, rest[0])
            if found is None or found[1] not in found[0]:
                return 1
            print(found[0][found[1]])
            return 0
        if command == "count":
            print(
                sum(
                    1
                    for sections in data.values()
                    for section in sections
                    if section.get("type") == rest[0]
                )
            )
            return 0
        return 1


    sys.exit(main(sys.argv[1:]))
    """
)

HARNESS = textwrap.dedent(
    """\
    #!/bin/sh
    TEST_ROOT="@ROOT@"
    TEST_BOARD="@BOARD@"
    TEST_UCI_STATE="$TEST_ROOT/uci-state.json"
    export TEST_UCI_STATE
    PATH="$TEST_ROOT/bin:$PATH"
    export PATH

    board_name() { printf '%s\\n' "$TEST_BOARD"; }
    config_load() { :; }
    config_foreach() {
        local fn="$1"
        local i=0 n
        n=$(uci -q count ubootenv)
        while [ "$i" -lt "$n" ]; do
            "$fn" "section$i"
            i=$((i + 1))
        done
    }
    config_get() {
        local var="$1" section="$2" opt="$3" def="${4:-}"
        local idx="${section#section}" val
        if [ "$opt" = TYPE ]; then
            eval "$var=ubootenv"
            return 0
        fi
        val=$(uci -q get "ubootenv.@ubootenv[$idx].$opt") || val=
        if [ -n "$val" ]; then
            eval "$var=\\$val"
        elif [ -n "$def" ]; then
            eval "$var=\\$def"
        fi
    }
    nand_find_ubi() {
        [ -n "@UBI_DEV@" ] || return 1
        printf '%s\\n' "@UBI_DEV@"
    }
    nand_find_volume() {
        case "$2" in
        ubootenv) [ -n "@VOL1@" ] && printf '%s\\n' "@VOL1@" ;;
        ubootenv2) [ -n "@VOL2@" ] && printf '%s\\n' "@VOL2@" ;;
        esac
    }
    find_mtd_index() { printf '%s\\n' 3; }
    . "$TEST_ROOT/board.sh"
    """
)

HELPER_HARNESS = textwrap.dedent(
    """\
    #!/bin/sh
    TEST_ROOT="@ROOT@"
    TEST_UCI_STATE="$TEST_ROOT/uci-state.json"
    export TEST_UCI_STATE
    PATH="$TEST_ROOT/bin:$PATH"
    export PATH

    nand_find_ubi() { printf '%s\\n' 0; }
    nand_find_volume() {
        case "$2" in
        ubootenv) printf '%s\\n' ubi0_1 ;;
        ubootenv2) printf '%s\\n' ubi0_2 ;;
        esac
    }
    . "$TEST_ROOT/lib/uboot-envtools.sh"
    ubootenv_add_ubi_default "$@"
    """
)


def write_sandbox(root, *, board=None, helper=None, source=None, seed_uci=None,
                  seed_fwenv=None, existing_config=False,
                  ubi_dev="0", vol1="ubi0_1", vol2="ubi0_2"):
    """Materialise a throwaway root and rewrite the absolute /lib, /etc paths.

    The scripts under test are copied verbatim except for the ``/lib`` and
    ``/etc`` prefixes, which move into the temporary root.  ``/dev`` paths are
    left alone: they are data written into fw_env.config, not host access.
    """
    root = Path(root)
    (root / "bin").mkdir(parents=True, exist_ok=True)
    (root / "etc").mkdir(exist_ok=True)
    (root / "lib" / "upgrade").mkdir(parents=True, exist_ok=True)

    (root / "lib" / "upgrade" / "nand.sh").write_text("")
    (root / "lib" / "functions.sh").write_text("")
    helper_text = Path(helper or helper_path()).read_text()
    (root / "lib" / "uboot-envtools.sh").write_text(
        helper_text.replace("/lib/", f"{root}/lib/").replace("/etc/", f"{root}/etc/")
    )
    source_text = Path(source or board_path()).read_text()
    (root / "board.sh").write_text(
        source_text.replace("/lib/", f"{root}/lib/").replace("/etc/", f"{root}/etc/")
    )

    uci = root / "bin" / "uci"
    uci.write_text(UCI_STUB)
    uci.chmod(0o755)

    state = root / "uci-state.json"
    state.write_text(json.dumps(seed_uci or {}))
    if seed_fwenv is not None:
        (root / "etc" / "fw_env.config").write_text(seed_fwenv)
    if existing_config:
        (root / "etc" / "config").mkdir(exist_ok=True)
        (root / "etc" / "config" / "ubootenv").write_text("config ubootenv\n")

    (root / "harness.sh").write_text(
        HARNESS.replace("@ROOT@", str(root))
        .replace("@BOARD@", board or "")
        .replace("@UBI_DEV@", ubi_dev)
        .replace("@VOL1@", vol1)
        .replace("@VOL2@", vol2)
    )
    (root / "helper-harness.sh").write_text(HELPER_HARNESS.replace("@ROOT@", str(root)))
    return root


def run_harness(root, name="harness.sh", *args):
    return subprocess.run(
        ["sh", str(Path(root) / name), *args],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def fwenv_rows(root):
    path = Path(root) / "etc" / "fw_env.config"
    if not path.exists():
        return []
    return [line.split() for line in path.read_text().splitlines() if line.strip()]


def uci_sections(root):
    path = Path(root) / "uci-state.json"
    return json.loads(path.read_text()).get("ubootenv", [])


class DefconfigTest(unittest.TestCase):
    """The expected size comes from the U-Boot side, not from the helper."""

    def test_gemtek_defconfigs_are_16k(self):
        self.assertEqual(defconfig_env_size(PATCH_XR, XR_DEFCONFIG), "0x4000")
        self.assertEqual(defconfig_env_size(PATCH_W1700K, W1700K_DEFCONFIG), "0x4000")

    def test_nokia_uses_the_kconfig_default(self):
        self.assertIsNone(
            defconfig_env_size(PATCH_NOKIA, NOKIA_DEFCONFIG),
            "nokia now sets CONFIG_ENV_SIZE explicitly; update u_boot_env_size()",
        )
        self.assertEqual(u_boot_env_size("nokia,xg-040g-md-ubi"), KCONFIG_ENV_SIZE_DEFAULT)


class HelperDefaultTest(unittest.TestCase):
    """Parameterising the helper must not move boards outside this issue.

    mediatek_filogic, mediatek_mt7622 and airoha_an7583 call the helper with no
    argument and their on-device fw_env.config is not part of #386, so the
    zero-argument default stays at the legacy one-LEB value.
    """

    def test_no_argument_default_is_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = write_sandbox(tmp, board="unused")
            result = run_harness(root, "helper-harness.sh")
            self.assertEqual(result.returncode, 0, result.stderr)
            sections = uci_sections(root)
            self.assertEqual(len(sections), 2, sections)
            for section in sections:
                self.assertEqual(section["options"]["envsize"], LEB_SIZE)
                self.assertEqual(section["options"]["secsize"], LEB_SIZE)
                self.assertEqual(section["options"]["numsec"], "1")

    def test_explicit_argument_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = write_sandbox(tmp, board="unused")
            result = run_harness(root, "helper-harness.sh", "0x4000", "0x1f000", "1")
            self.assertEqual(result.returncode, 0, result.stderr)
            for section in uci_sections(root):
                self.assertEqual(section["options"]["envsize"], "0x4000")


class BoardContractTest(unittest.TestCase):
    """Fresh install: the board script writes the U-Boot size into fw_env.config."""

    def assert_contract(self, root, board):
        expected = u_boot_env_size(board)
        rows = fwenv_rows(root)
        self.assertEqual(
            [row[0] for row in rows],
            ["/dev/ubi0_1", "/dev/ubi0_2"],
            f"{board}: unexpected fw_env.config rows: {rows}",
        )
        for row in rows:
            self.assertEqual(len(row), 5, row)
            self.assertEqual(
                row[2],
                expected,
                f"{board}: fw_env.config envsize {row[2]} != U-Boot CONFIG_ENV_SIZE {expected}",
            )
            self.assertEqual(row[3], LEB_SIZE, row)
            self.assertEqual(row[4], "1", row)

    def test_each_board_matches_its_u_boot_env_size(self):
        for board, _, _ in BOARD_CASES:
            with self.subTest(board=board):
                with tempfile.TemporaryDirectory() as tmp:
                    root = write_sandbox(tmp, board=board)
                    result = run_harness(root)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assert_contract(root, board)

    def test_one_leb_drift_is_detected(self):
        """A copy that puts 0x1f000 back where 0x4000 belongs must go red."""
        with tempfile.TemporaryDirectory() as tmp:
            drifted = Path(tmp) / "airoha_an7581.old"
            drifted.write_text(
                board_path().read_text().replace('"0x4000"', f'"{LEB_SIZE}"')
            )
            with tempfile.TemporaryDirectory() as root_tmp:
                root = write_sandbox(root_tmp, board="gemtek,xr1710g-ubi", source=drifted)
                result = run_harness(root)
                self.assertEqual(result.returncode, 0, result.stderr)
                with self.assertRaises(AssertionError):
                    self.assert_contract(root, "gemtek,xr1710g-ubi")


class MigrationTest(unittest.TestCase):
    """Upgrade: existing conffiles must be rewritten, no flash write involved."""

    OLD_FWENV = (
        "/dev/ubi0_1 0x0 0x1f000 0x1f000 1\n"
        "/dev/ubi0_2 0x0 0x1f000 0x1f000 1\n"
    )

    @staticmethod
    def old_state(dev1="/dev/ubi0_1", dev2="/dev/ubi0_2"):
        options = {
            "offset": "0x0",
            "envsize": "0x1f000",
            "secsize": "0x1f000",
            "numsec": "1",
        }
        return {
            "ubootenv": [
                {"type": "ubootenv", "name": None, "options": dict(options, dev=dev1)},
                {"type": "ubootenv", "name": None, "options": dict(options, dev=dev2)},
            ]
        }

    def test_gemtek_upgrade_migrates_both_conffiles(self):
        for board in ("gemtek,xr1710g-ubi", "gemtek,w1700k-ubi"):
            with self.subTest(board=board):
                with tempfile.TemporaryDirectory() as tmp:
                    root = write_sandbox(
                        tmp,
                        board=board,
                        seed_uci=self.old_state(),
                        seed_fwenv=self.OLD_FWENV,
                        existing_config=True,
                    )
                    for attempt in (1, 2):
                        result = run_harness(root)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        sections = uci_sections(root)
                        self.assertEqual(len(sections), 2, sections)
                        for section in sections:
                            options = section["options"]
                            self.assertEqual(options["envsize"], "0x4000", (attempt, options))
                            self.assertEqual(options["secsize"], LEB_SIZE)
                            self.assertEqual(options["numsec"], "1")
                        rows = fwenv_rows(root)
                        self.assertEqual(len(rows), 2, rows)
                        for row in rows:
                            self.assertEqual(
                                row[2:], ["0x4000", LEB_SIZE, "1"], (attempt, row)
                            )

    def test_gemtek_upgrade_migrates_ubi0_0_and_ubi0_1_layout(self):
        """XR1710G DTS puts ubootenv on ubi0_0 and ubootenv2 on ubi0_1.

        Hardcoding /dev/ubi0_1|/dev/ubi0_2 leaves /dev/ubi0_0 at 0x1f000 while
        rewriting /dev/ubi0_1 to 0x4000, creating an asymmetric redundant env.
        """
        old_fwenv = (
            "/dev/ubi0_0 0x0 0x1f000 0x1f000 1\n"
            "/dev/ubi0_1 0x0 0x1f000 0x1f000 1\n"
        )
        for board in ("gemtek,xr1710g-ubi", "gemtek,w1700k-ubi"):
            with self.subTest(board=board):
                with tempfile.TemporaryDirectory() as tmp:
                    root = write_sandbox(
                        tmp,
                        board=board,
                        seed_uci=self.old_state("/dev/ubi0_0", "/dev/ubi0_1"),
                        seed_fwenv=old_fwenv,
                        existing_config=True,
                        ubi_dev="ubi0",
                        vol1="ubi0_0",
                        vol2="ubi0_1",
                    )
                    for attempt in (1, 2):
                        result = run_harness(root)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        sections = uci_sections(root)
                        self.assertEqual(len(sections), 2, sections)
                        for section in sections:
                            options = section["options"]
                            self.assertEqual(
                                options["envsize"], "0x4000", (attempt, options)
                            )
                            self.assertEqual(options["secsize"], LEB_SIZE)
                            self.assertEqual(options["numsec"], "1")
                        rows = fwenv_rows(root)
                        self.assertEqual(
                            [row[0] for row in rows],
                            ["/dev/ubi0_0", "/dev/ubi0_1"],
                            rows,
                        )
                        for row in rows:
                            self.assertEqual(
                                row[2:], ["0x4000", LEB_SIZE, "1"], (attempt, row)
                            )

    def test_gemtek_upgrade_migrates_without_sysfs_fallback(self):
        """When sysfs/UBI is unavailable, fall back to /dev/ubi<N>_<M> only."""
        old_fwenv = (
            "/dev/ubi0_0 0x0 0x1f000 0x1f000 1\n"
            "/dev/ubi0_1 0x0 0x1f000 0x1f000 1\n"
            "/dev/mtd3 0x0 0x1f000 0x1f000 1\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = write_sandbox(
                tmp,
                board="gemtek,xr1710g-ubi",
                seed_uci=self.old_state("/dev/ubi0_0", "/dev/ubi0_1"),
                seed_fwenv=old_fwenv,
                existing_config=True,
                ubi_dev="",
                vol1="",
                vol2="",
            )
            result = run_harness(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            for section in uci_sections(root):
                self.assertEqual(section["options"]["envsize"], "0x4000", section)
            rows = fwenv_rows(root)
            self.assertEqual(len(rows), 3, rows)
            self.assertEqual(rows[0][2:], ["0x4000", LEB_SIZE, "1"], rows[0])
            self.assertEqual(rows[1][2:], ["0x4000", LEB_SIZE, "1"], rows[1])
            self.assertEqual(rows[2], ["/dev/mtd3", "0x0", "0x1f000", "0x1f000", "1"], rows[2])

    def test_gemtek_standalone_stale_fw_env_config_is_migrated(self):
        """A stale /etc/fw_env.config without /etc/config/ubootenv must still migrate."""
        old_fwenv = (
            "/dev/ubi0_0 0x0 0x1f000 0x1f000 1\n"
            "/dev/ubi0_1 0x0 0x1f000 0x1f000 1\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = write_sandbox(
                tmp,
                board="gemtek,xr1710g-ubi",
                seed_uci={},
                seed_fwenv=old_fwenv,
                existing_config=False,
                ubi_dev="ubi0",
                vol1="ubi0_0",
                vol2="ubi0_1",
            )
            result = run_harness(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = fwenv_rows(root)
            self.assertEqual(
                [row[0] for row in rows],
                ["/dev/ubi0_0", "/dev/ubi0_1"],
                rows,
            )
            for row in rows:
                self.assertEqual(row[2:], ["0x4000", LEB_SIZE, "1"], row)

    def test_nokia_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = write_sandbox(
                tmp,
                board="nokia,xg-040g-md-ubi",
                seed_uci=self.old_state(),
                seed_fwenv=self.OLD_FWENV,
                existing_config=True,
            )
            result = run_harness(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            for section in uci_sections(root):
                self.assertEqual(section["options"]["envsize"], KCONFIG_ENV_SIZE_DEFAULT)
            for row in fwenv_rows(root):
                self.assertEqual(row[2], KCONFIG_ENV_SIZE_DEFAULT)


if __name__ == "__main__":
    unittest.main()
