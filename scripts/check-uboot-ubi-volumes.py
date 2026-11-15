#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check that the UBI volumes named by the XR1710G U-Boot environment exist.

The U-Boot default environment for the Gemtek XR1710G is shipped as a patch
to the uboot-airoha package and refers to UBI volumes by name (``ubi check
<volume>``, ``ubi read <address> <volume>``).  The board UBI layout lives in
the Linux DTS, so the two can drift apart silently: a typo or a removed volume
then only shows up as a boot failure on the board.

This script parses every ``ubi check``/``ubi read`` command in the environment
patch, collects the referenced volume names and compares them with the
``volname`` properties of the board DTS.  It exits non-zero and names the
missing volumes when the two disagree, so the check can be run before a build.

Usage:
    scripts/check-uboot-ubi-volumes.py
    scripts/check-uboot-ubi-volumes.py --uboot-patch <file> --dts <file>
    scripts/check-uboot-ubi-volumes.py --selftest

Exit codes: 0 = every referenced volume is defined, 1 = mismatch,
2 = unreadable input or an unparsable command.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PATCH = (
    REPO_ROOT / "package/boot/uboot-airoha/patches/999-airoha-add-gemtek-xr1710g.patch"
)
DEFAULT_DTS = REPO_ROOT / "target/linux/airoha/dts/an7581-xr1710g-ubi.dts"

ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
VOLNAME = re.compile(r'volname\s*=\s*"([^"]+)"')
COMMAND_SEPARATOR = re.compile(r"\s*(?:&&|\|\||;|\|)\s*")

# U-Boot 2026.07 syntax:
#   ubi check <volume>
#   ubi read <address> <volume> [<size>]
# ``readvol`` is accepted as an alias by the command, so the read sub-command
# is matched by prefix.
UBI_READ = "read"
UBI_CHECK = "check"


class InputError(Exception):
    """Raised when an input file cannot be parsed."""


def looks_like_patch(text: str) -> bool:
    """Return True for a unified patch, using both git and plain markers."""
    return "diff --git " in text or any(
        line.startswith("+++ ") for line in text.splitlines()
    )


def _env_lines(text: str, patch: bool) -> list[str]:
    """Yield the environment text lines, skipping patch metadata and comments."""
    lines: list[str] = []
    for raw in text.splitlines():
        if patch:
            # Skip the +++/--- file headers and only look at added lines.
            if raw.startswith("+++") or raw.startswith("---"):
                continue
            if not raw.startswith("+"):
                continue
            raw = raw[1:]
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        lines.append(stripped)
    return lines


def parse_env_volumes(text: str, *, patch: bool = False) -> list[tuple[str, str]]:
    """Return (command, volume) pairs referenced by an environment file."""
    found: list[tuple[str, str]] = []
    for line in _env_lines(text, patch):
        name, sep, value = line.partition("=")
        if sep:
            if not ENV_NAME.fullmatch(name):
                # Not a variable assignment (e.g. a patch index line).
                continue
        else:
            value = line

        for command in COMMAND_SEPARATOR.split(value):
            tokens = command.split()
            if len(tokens) < 2 or tokens[0] != "ubi":
                continue
            subcommand = tokens[1]
            if subcommand == UBI_CHECK:
                if len(tokens) < 3:
                    raise InputError(f"{line!r}: 'ubi check' without a volume name")
                volume = tokens[2]
            elif subcommand.startswith(UBI_READ):
                # argv is [ubi, read, address, volume, (size)].
                if len(tokens) < 4:
                    raise InputError(
                        f"{line!r}: 'ubi {subcommand}' without an address and volume"
                    )
                volume = tokens[3]
            else:
                continue
            found.append((f"ubi {subcommand}", volume))
    return found


def parse_dts_volumes(text: str) -> set[str]:
    """Return the volume names defined by the DTS ``volname`` properties."""
    return set(VOLNAME.findall(text))


def missing_volumes(env_text: str, dts_text: str, *, patch: bool = False) -> list[str]:
    """Return the referenced volume names that the DTS does not define."""
    referenced = {volume for _, volume in parse_env_volumes(env_text, patch=patch)}
    defined = parse_dts_volumes(dts_text)
    return sorted(referenced - defined)


def _format_missing(referenced: list[tuple[str, str]], missing: list[str]) -> str:
    by_volume: dict[str, list[str]] = {}
    for command, volume in referenced:
        by_volume.setdefault(volume, []).append(command)
    lines = ["UBI volumes referenced by the U-Boot environment but not defined in the DTS:"]
    for volume in missing:
        commands = ", ".join(sorted(set(by_volume[volume])))
        lines.append(f"  {volume} (used by {commands})")
    return "\n".join(lines)


def _display(path: Path) -> str:
    """Return a path relative to the current directory when possible."""
    try:
        return str(path.relative_to(Path.cwd()))
    except ValueError:
        return str(path)


def check_files(patch_path: Path, dts_path: Path) -> int:
    try:
        patch_text = patch_path.read_text(encoding="utf-8")
        dts_text = dts_path.read_text(encoding="utf-8")
    except OSError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2

    try:
        referenced = parse_env_volumes(patch_text, patch=looks_like_patch(patch_text))
    except InputError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2
    defined = parse_dts_volumes(dts_text)
    if not referenced:
        print(f"error: no 'ubi read'/'ubi check' command found in {_display(patch_path)}",
              file=sys.stderr)
        return 2
    missing = sorted({volume for _, volume in referenced} - defined)
    if missing:
        print(_format_missing(referenced, missing), file=sys.stderr)
        print(f"defined in {_display(dts_path)}: {', '.join(sorted(defined))}", file=sys.stderr)
        return 1

    used = ", ".join(sorted({volume for _, volume in referenced}))
    print(f"OK: {_display(patch_path)} only uses volumes defined in {_display(dts_path)}: {used}")
    return 0


# --- self-test ------------------------------------------------------------

_SELFTEST_ENV = (
    "bootfile=openwrt-airoha-an7581-gemtek_xr1710g-ubi-initramfs-recovery.itb\n"
    "boot_production=run ubi_read_production\n"
    "boot_recovery=echo no flash recovery volume\n"
    "ubi_read_recovery=ubi check {volume} && ubi read $initaddr {volume}\n"
    "ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr\n"
).format(volume="recovery")

_SELFTEST_DTS = """
&spi_nand {
	partitions {
		partition@700000 {
			volumes {
				ubi-volume-ubootenv {
					volname = "ubootenv";
				};

				ubi-volume-fit {
					volname = "fit";
				};
@@RECOVERY@@
			};
		};
	};
};
"""

_SELFTEST_DTS_WITH_RECOVERY = _SELFTEST_DTS.replace(
    "@@RECOVERY@@",
    """				ubi-volume-recovery {
					volname = "recovery";
				};
""",
)
_SELFTEST_DTS_WITHOUT_RECOVERY = _SELFTEST_DTS.replace("@@RECOVERY@@\n", "")


def _as_patch(env_text: str) -> str:
    """Wrap synthetic environment text in a minimal new-file patch."""
    lines = env_text.splitlines()
    header = [
        "diff --git a/defenvs/selftest b/defenvs/selftest",
        "new file mode 100644",
        "--- /dev/null",
        "+++ b/defenvs/selftest",
        f"@@ -0,0 +1,{len(lines)} @@",
    ]
    return "\n".join(header + ["+" + line for line in lines]) + "\n"


def _as_plain_patch(env_text: str) -> str:
    """Wrap environment text like a quilt patch without diff --git markers."""
    lines = env_text.splitlines()
    header = [
        "--- /dev/null",
        "+++ b/defenvs/selftest",
        f"@@ -0,0 +1,{len(lines)} @@",
    ]
    return "\n".join(header + ["+" + line for line in lines]) + "\n"


def selftest() -> int:
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        patch_path = tmpdir / "env.patch"
        patch_path.write_text(_as_patch(_SELFTEST_ENV), encoding="utf-8")
        plain_path = tmpdir / "env-plain.patch"
        plain_path.write_text(_as_plain_patch(_SELFTEST_ENV), encoding="utf-8")

        dts_all = tmpdir / "all.dts"
        dts_all.write_text(_SELFTEST_DTS_WITH_RECOVERY, encoding="utf-8")
        dts_missing = tmpdir / "missing.dts"
        dts_missing.write_text(_SELFTEST_DTS_WITHOUT_RECOVERY, encoding="utf-8")

        missing = missing_volumes(_SELFTEST_ENV, _SELFTEST_DTS_WITHOUT_RECOVERY)
        if missing == ["recovery"]:
            print("selftest: missing-recovery case names 'recovery' [ok]")
        else:
            print(f"selftest: missing-recovery case returned {missing!r} [FAIL]")
            failures += 1

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            rc_all = check_files(patch_path, dts_all)
        if rc_all == 0:
            print("selftest: all-volumes-present case passes [ok]")
        else:
            print(f"selftest: all-volumes-present case exited {rc_all} [FAIL]")
            failures += 1

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            rc_missing = check_files(patch_path, dts_missing)
        if rc_missing == 1:
            print("selftest: missing-recovery case exits 1 [ok]")
        else:
            print(f"selftest: missing-recovery case exited {rc_missing}, expected 1 [FAIL]")
            failures += 1

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            rc_plain = check_files(plain_path, dts_missing)
        if rc_plain == 1:
            print("selftest: patch without diff --git markers exits 1 [ok]")
        else:
            print(f"selftest: patch without diff --git markers exited {rc_plain} [FAIL]")
            failures += 1

    if failures:
        print(f"selftest: {failures} case(s) failed", file=sys.stderr)
        return 1
    print("selftest: all cases passed")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--uboot-patch", type=Path, default=DEFAULT_PATCH, help="U-Boot environment patch"
    )
    parser.add_argument(
        "--dts", type=Path, default=DEFAULT_DTS, help="board DTS with the UBI volumes"
    )
    parser.add_argument("--selftest", action="store_true", help="run the built-in self-test")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()
    return check_files(args.uboot_patch, args.dts)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
