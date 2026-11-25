#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check that the UBI volumes named by the XR1710G U-Boot environment exist.

The U-Boot default environment for the Gemtek XR1710G is shipped as a patch
to the uboot-airoha package and refers to UBI volumes by name (``ubi check
<volume>``, ``ubi read <address> <volume>``).  The board UBI layout lives in
the Linux DTS, so the two can drift apart silently: a typo or a removed volume
then only shows up as a boot failure on the board.

This script validates unified-diff hunk line counts on the U-Boot patch (so an
undercounted hunk header cannot let ``patch(1)`` silently drop trailing lines),
parses every ``ubi check``/``ubi read`` command in the environment patch,
collects the referenced volume names and compares them with the ``volname``
properties of the board DTS.  It exits non-zero and names the missing volumes
(or malformed hunk) when the two disagree, so the check can be run before a build.

Usage:
    scripts/check-uboot-ubi-volumes.py
    scripts/check-uboot-ubi-volumes.py --uboot-patch <file> --dts <file>
    scripts/check-uboot-ubi-volumes.py --selftest

Exit codes: 0 = every referenced volume is defined, 1 = mismatch,
2 = unreadable input, malformed patch hunk, or an unparsable command.
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
HUNK_HEADER = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")

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


def validate_patch_hunks(text: str) -> None:
    """Verify every unified-diff hunk header matches its body -/+ line counts.

    ``patch(1)`` stops reading a hunk once the header's line count is reached
    and treats any extra trailing ``+`` lines as inter-hunk text, silently
    dropping them.  Validate every hunk so an undercounted (or overcounted)
    header fails loudly before build time.
    """
    lines = text.splitlines()
    total = len(lines)
    i = 0
    current_file = "<patch>"
    hunks_seen = 0
    in_file = False
    file_has_hunk = True
    file_header_line = 0

    def is_file_boundary(idx: int, *, counts_satisfied: bool = True) -> bool:
        line = lines[idx]
        if line.startswith("diff --git ") or line.startswith("Index: "):
            return True
        if line.startswith("--- ") and idx + 1 < total and lines[idx + 1].startswith("+++ "):
            if counts_satisfied:
                return True
            if idx + 2 < total and HUNK_HEADER.match(lines[idx + 2]):
                return True
        return False

    while i < total:
        line = lines[i]
        if line.startswith("diff --git ") or line.startswith("Index: "):
            if not file_has_hunk:
                raise InputError(
                    f"{current_file}: patch header at line {file_header_line} has no hunk"
                )
            in_file = False
            file_has_hunk = True
            i += 1
            continue
        if line == "-- ":
            in_file = False
            i += 1
            continue
        if line.startswith("--- ") and i + 1 < total and lines[i + 1].startswith("+++ "):
            if not file_has_hunk:
                raise InputError(
                    f"{current_file}: patch header at line {file_header_line} has no hunk"
                )
            target = lines[i + 1][4:].split("\t", 1)[0].strip()
            if target.startswith("b/"):
                target = target[2:]
            current_file = target or "<patch>"
            file_header_line = i + 2
            in_file = True
            file_has_hunk = False
            i += 2
            continue

        if not in_file:
            i += 1
            continue

        match = HUNK_HEADER.match(line)
        if not match:
            i += 1
            continue

        file_has_hunk = True
        hunks_seen += 1
        hunk_line = i + 1
        header = line
        exp_old = int(match.group(2)) if match.group(2) is not None else 1
        exp_new = int(match.group(4)) if match.group(4) is not None else 1
        act_old = 0
        act_new = 0
        i += 1

        while i < total:
            body = lines[i]
            satisfied = act_old == exp_old and act_new == exp_new
            if is_file_boundary(i, counts_satisfied=satisfied) or HUNK_HEADER.match(body):
                break
            if body == "-- " and satisfied:
                in_file = False
                i = total
                break
            if body.startswith("+"):
                act_new += 1
            elif body.startswith("-"):
                act_old += 1
            elif body.startswith(" "):
                act_old += 1
                act_new += 1
            elif body.startswith("\\ No newline at end of file"):
                pass
            elif body == "":
                j = i + 1
                while j < total and lines[j] == "":
                    j += 1
                at_boundary = (
                    j >= total
                    or is_file_boundary(j, counts_satisfied=satisfied)
                    or HUNK_HEADER.match(lines[j])
                    or (satisfied and lines[j] == "-- ")
                )
                if satisfied:
                    if at_boundary:
                        i = j
                        break
                    raise InputError(
                        f"{current_file}: unexpected trailing content at line {j + 1} "
                        f"after completed hunk at line {hunk_line}: {lines[j]!r}"
                    )
                if exp_old > 0 and act_old < exp_old and act_new < exp_new:
                    act_old += 1
                    act_new += 1
                elif at_boundary:
                    i = j
                    break
                else:
                    raise InputError(
                        f"{current_file}: unexpected blank line {i + 1} inside hunk at line {hunk_line}"
                    )
            else:
                raise InputError(
                    f"{current_file}: unexpected line {i + 1} inside hunk at line {hunk_line}: {body!r}"
                )
            i += 1

        if act_old != exp_old or act_new != exp_new:
            extra = ""
            if act_new > exp_new:
                extra = f" (patch(1) would silently drop {act_new - exp_new} added line(s))"
            raise InputError(
                f"{current_file}: hunk at line {hunk_line} ({header}) declares "
                f"-{exp_old}/+{exp_new} lines, but body has -{act_old}/+{act_new}{extra}"
            )

    if not file_has_hunk:
        raise InputError(
            f"{current_file}: patch header at line {file_header_line} has no hunk"
        )
    if hunks_seen == 0:
        raise InputError("patch contains no unified-diff hunks")


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
    if patch:
        validate_patch_hunks(text)
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

        truncated_lines = _SELFTEST_ENV.splitlines()
        truncated_patch = tmpdir / "env-truncated.patch"
        truncated_patch.write_text(
            "\n".join(
                [
                    "--- /dev/null",
                    "+++ b/defenvs/selftest",
                    f"@@ -0,0 +1,{len(truncated_lines) - 2} @@",
                    *["+" + line for line in truncated_lines],
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        trunc_err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(trunc_err):
            rc_trunc = check_files(truncated_patch, dts_all)
        if rc_trunc == 2 and "silently drop" in trunc_err.getvalue():
            print("selftest: undercounted hunk header exits 2 [ok]")
        else:
            print(
                f"selftest: undercounted hunk header exited {rc_trunc} "
                f"(stderr={trunc_err.getvalue()!r}) [FAIL]"
            )
            failures += 1

        over_patch = tmpdir / "env-overcount.patch"
        over_patch.write_text(
            "\n".join(
                [
                    "--- /dev/null",
                    "+++ b/defenvs/selftest",
                    f"@@ -0,0 +1,{len(truncated_lines) + 2} @@",
                    *["+" + line for line in truncated_lines],
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            rc_over = check_files(over_patch, dts_all)
        if rc_over == 2:
            print("selftest: overcounted hunk header exits 2 [ok]")
        else:
            print(f"selftest: overcounted hunk header exited {rc_over}, expected 2 [FAIL]")
            failures += 1

        valid_constructs_patch = tmpdir / "env-valid-constructs.patch"
        valid_constructs_patch.write_text(
            "\n".join(
                [
                    "Subject: [PATCH] mention @@ -1,2 +1,3 @@ in commit message",
                    "",
                    "Example hunk header @@ -0,0 +1,99 @@ inside commit prose.",
                    "---",
                    "Index: defenvs/selftest",
                    "===================================================================",
                    "--- a/defenvs/selftest",
                    "+++ b/defenvs/selftest",
                    "@@ -1,4 +1,4 @@",
                    " # keep comment",
                    "",
                    "--- old_marker",
                    "+++ new_marker",
                    "-ubi_read_production=ubi read $loadaddr old && iminfo $loadaddr",
                    "+ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr",
                    "",
                    "-- ",
                    "2.43.0",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        valid_err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(valid_err):
            rc_valid = check_files(valid_constructs_patch, dts_all)
        if rc_valid == 0:
            print("selftest: commit @@, Index:, mid-hunk ---/+++, stripped context & -- footer pass [ok]")
        else:
            print(
                f"selftest: valid unified-diff constructs exited {rc_valid} "
                f"(stderr={valid_err.getvalue()!r}) [FAIL]"
            )
            failures += 1

        for label, patch_lines in (
            (
                "undercounted new-file hunk blank then +dropped=1",
                [
                    "--- /dev/null",
                    "+++ b/defenvs/selftest",
                    "@@ -0,0 +1,2 @@",
                    "+boot_production=run ubi_read_production",
                    "+ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr",
                    "",
                    "+dropped=1",
                ],
            ),
            (
                "undercounted mod hunk blank then +dropped=1",
                [
                    "--- a/defenvs/selftest",
                    "+++ b/defenvs/selftest",
                    "@@ -1,2 +1,2 @@",
                    " boot_production=run ubi_read_production",
                    "-ubi_read_production=ubi read $loadaddr old",
                    "+ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr",
                    "",
                    "+dropped=1",
                ],
            ),
        ):
            bad_blank = tmpdir / f"{label.replace(' ', '_')}.patch"
            bad_blank.write_text("\n".join(patch_lines) + "\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
                io.StringIO()
            ):
                rc_bad = check_files(bad_blank, dts_all)
            if rc_bad == 2:
                print(f"selftest: {label} exits 2 [ok]")
            else:
                print(f"selftest: {label} exited {rc_bad}, expected 2 [FAIL]")
                failures += 1

        for label, patch_lines in (
            (
                "trailing stripped context before next @@",
                [
                    "--- a/defenvs/selftest",
                    "+++ b/defenvs/selftest",
                    "@@ -1,2 +1,2 @@",
                    "-ubi_read_production=ubi read $loadaddr old",
                    "+ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr",
                    "",
                    "@@ -10,1 +10,1 @@",
                    "-bootdelay=1",
                    "+bootdelay=3",
                ],
            ),
            (
                "trailing stripped context before next file",
                [
                    "--- a/defenvs/selftest",
                    "+++ b/defenvs/selftest",
                    "@@ -1,2 +1,2 @@",
                    "-ubi_read_production=ubi read $loadaddr old",
                    "+ubi_read_production=ubi read $loadaddr fit && iminfo $loadaddr",
                    "",
                    "--- a/f2",
                    "+++ b/f2",
                    "@@ -1,1 +1,1 @@",
                    "-a=1",
                    "+a=2",
                ],
            ),
        ):
            good_tail = tmpdir / f"{label.replace(' ', '_')}.patch"
            good_tail.write_text("\n".join(patch_lines) + "\n", encoding="utf-8")
            tail_err = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(tail_err):
                rc_tail = check_files(good_tail, dts_all)
            if rc_tail == 0:
                print(f"selftest: {label} passes [ok]")
            else:
                print(
                    f"selftest: {label} exited {rc_tail} "
                    f"(stderr={tail_err.getvalue()!r}) [FAIL]"
                )
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
