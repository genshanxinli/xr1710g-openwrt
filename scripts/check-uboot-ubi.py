#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Cross-layer U-Boot patch, UBI DTS, uboot-envtools, and KASLR Makefile gate for XR1710G."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
CMD_SEP_RE = re.compile(r"\s*(?:&&|\|\||;|\|)\s*")
VOLNAME_RE = re.compile(r'volname\s*=\s*"([^"]+)"')
INCLUDE_RE = re.compile(r'^\s*#include\s+"([^"]+)"', re.MULTILINE)
BUILD_CFG_RE = re.compile(r"^define Build/Configure\n(.*?)^endef$", re.MULTILINE | re.DOTALL)
MAKE_VAR_RE = re.compile(r"\$(?:\([^()$]+\)|\{[^{}$]+\})")
HUSH_PREFIX = frozenset({"if", "elif", "then", "else", "do", "!"})
RUNTIME_UBI_VOLUMES = frozenset({"rootfs_data"})
KASLR_REQ = ("CONFIG_DM_RNG=y", "CONFIG_RNG_AIROHA=y")
KASLR_FORBID = ("CONFIG_MEASURED_BOOT=y", "CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT=y")


class PatchError(Exception):
    pass


def validate_and_split_patch(text: str) -> dict[str, list[str]]:
    lines = text.splitlines()
    total = len(lines)
    i, cur, in_f, has_h, hdr_ln, hunks = 0, "<patch>", False, True, 0, 0
    added: dict[str, list[str]] = {}

    def boundary(idx: int, sat: bool) -> bool:
        ln = lines[idx]
        if ln.startswith(("diff --git ", "Index: ")):
            return True
        return ln.startswith("--- ") and idx + 1 < total and lines[idx + 1].startswith("+++ ") and (
            sat or (idx + 2 < total and bool(HUNK_RE.match(lines[idx + 2])))
        )

    while i < total:
        ln = lines[i]
        if ln.startswith(("diff --git ", "Index: ")) or ln == "-- ":
            if not has_h and ln != "-- ":
                raise PatchError(f"{cur}: header at line {hdr_ln} has no hunk")
            in_f, has_h, i = False, True, i + 1
            continue
        if ln.startswith("--- ") and i + 1 < total and lines[i + 1].startswith("+++ "):
            if not has_h:
                raise PatchError(f"{cur}: header at line {hdr_ln} has no hunk")
            tgt = lines[i + 1][4:].split("\t", 1)[0].strip()
            cur = tgt[2:] if tgt.startswith("b/") else (tgt or "<patch>")
            hdr_ln, in_f, has_h, i = i + 2, True, False, i + 2
            added.setdefault(cur, [])
            continue
        m = HUNK_RE.match(ln) if in_f else None
        if not m:
            i += 1
            continue
        has_h, hunks, hline = True, hunks + 1, i + 1
        eo = int(m.group(2)) if m.group(2) is not None else 1
        en = int(m.group(4)) if m.group(4) is not None else 1
        ao = an = 0
        i += 1
        while i < total:
            b = lines[i]
            sat = ao == eo and an == en
            if boundary(i, sat) or HUNK_RE.match(b):
                break
            if b == "-- " and sat:
                in_f, i = False, total
                break
            if b.startswith("+"):
                an += 1
                added[cur].append(b[1:])
            elif b.startswith("-"):
                ao += 1
            elif b.startswith(" "):
                ao, an = ao + 1, an + 1
            elif b.startswith("\\ No newline"):
                pass
            elif b == "":
                j = i + 1
                while j < total and lines[j] == "":
                    j += 1
                at_end = j >= total or boundary(j, sat) or bool(HUNK_RE.match(lines[j])) or (sat and lines[j] == "-- ")
                if (sat and at_end) or (not (eo > 0 and ao < eo and an < en) and at_end):
                    i = j
                    break
                if not sat and eo > 0 and ao < eo and an < en:
                    ao, an = ao + 1, an + 1
                else:
                    raise PatchError(f"{cur}: unexpected blank/trailing line at {i + 1} (hunk {hline})")
            else:
                raise PatchError(f"{cur}: invalid hunk line {i + 1}: {b!r}")
            i += 1
        if ao != eo or an != en:
            raise PatchError(f"{cur}: hunk at line {hline} declares -{eo}/+{en}, got -{ao}/+{an}")
    if not has_h:
        raise PatchError(f"{cur}: header at line {hdr_ln} has no hunk")
    if hunks == 0:
        raise PatchError("patch contains no unified-diff hunks")
    return added


def collect_dts_volumes(paths: list[Path]) -> tuple[set[str], list[Path]]:
    visited, seen, vols = [], set(), set()

    def walk(path: Path) -> None:
        rp = path.resolve()
        if rp in seen:
            return
        seen.add(rp)
        text = path.read_text(encoding="utf-8")
        visited.append(path)
        vols.update(VOLNAME_RE.findall(text))
        for inc in INCLUDE_RE.findall(text):
            if (path.parent / inc).is_file():
                walk(path.parent / inc)

    for p in paths:
        walk(p)
    return vols, visited


def parse_env_ubi_volumes(env_lines: list[str]) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    for raw in env_lines:
        ln = raw.strip()
        if not ln or ln.startswith("#"):
            continue
        k, sep, v = ln.partition("=")
        for cmd in CMD_SEP_RE.split(v if (sep and ENV_NAME_RE.match(k)) else ln):
            t = cmd.split()
            while t and t[0] in HUSH_PREFIX:
                t = t[1:]
            if len(t) >= 2 and t[0] == "ubi":
                if t[1] == "check":
                    if len(t) < 3:
                        raise PatchError(f"malformed ubi check: {ln!r}")
                    found.append(("ubi check", t[2]))
                elif t[1].startswith("read"):
                    if len(t) < 4:
                        raise PatchError(f"malformed ubi {t[1]}: {ln!r}")
                    found.append((f"ubi {t[1]}", t[3]))
    return found


def check_envtools(text: str, want_size: str) -> str | None:
    flat = re.sub(r"\\\n", "", text)
    for m in re.finditer(r"([^\n;]*gemtek,xr1710g-ubi[^\n;]*)\)(.*?);;", flat, re.DOTALL):
        call = re.search(r"\bubootenv_add_ubi_default\b([^\n;]*)", m.group(2))
        if call:
            args = [a.strip("\"'").lower() for a in call.group(1).split()]
            if len(args) >= 2 and args[0] == want_size.lower() and args[1] == "0x1f000":
                return None
            return f"ubootenv_add_ubi_default args {args!r} != [{want_size.lower()!r}, '0x1f000']"
    return "no gemtek,xr1710g-ubi ubootenv_add_ubi_default arm found"


def check_uboot_makefile(text: str) -> list[str]:
    errs: list[str] = []
    m_cust = re.search(r"^UBOOT_CUSTOMIZE_CONFIG\s*:?=\s*(.+)$", re.sub(r"\\\n", " ", text), re.MULTILINE)
    if not m_cust:
        errs.append("UBOOT_CUSTOMIZE_CONFIG missing")
    else:
        cust = m_cust.group(1)
        errs.extend(f"UBOOT_CUSTOMIZE_CONFIG missing {o!r}" for o in ("--enable DM_RNG", "--enable RNG_AIROHA") if o not in cust)
        errs.extend(f"UBOOT_CUSTOMIZE_CONFIG must not set {o!r}" for o in ("--enable MEASURED_BOOT", "--enable ARMV8_SEC_FIRMWARE_SUPPORT") if o in cust)
    m_cfg = BUILD_CFG_RE.search(text)
    if not m_cfg:
        return errs + ["define Build/Configure block missing"]
    active = [ln.strip() for ln in re.sub(r"\\\n", " ", m_cfg.group(1)).splitlines() if ln.strip() and not ln.strip().startswith("#")]
    for sym in KASLR_REQ:
        pos = re.compile(rf"(?:grep\b.*{re.escape(sym)}.*\|\|.*exit\s+[1-9]|if\s+!\s*grep\b.*{re.escape(sym)}.*exit\s+[1-9])")
        if not any(pos.search(ln) for ln in active):
            errs.append(f"Build/Configure missing positive KASLR assertion for {sym}")
    for sym in KASLR_FORBID:
        neg = re.compile(rf"(?:if\s+grep\b.*{re.escape(sym)}.*exit\s+[1-9]|grep\b.*{re.escape(sym)}.*&&.*exit\s+[1-9]|!\s*grep\b.*{re.escape(sym)}.*\|\|.*exit\s+[1-9])")
        if not any(neg.search(ln) for ln in active):
            errs.append(f"Build/Configure missing negative KASLR assertion forbidding {sym}")
    for lineno, raw in enumerate(m_cfg.group(1).splitlines(), 1):
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        cleaned = s.replace("$$$$", "")
        while (nxt := MAKE_VAR_RE.sub("", cleaned)) != cleaned:
            cleaned = nxt
        if "$" in cleaned:
            errs.append(f"Build/Configure line {lineno} has bare/double-expanded '$': {s}")
    return errs


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", type=Path, default=REPO_ROOT, help="repository root")
    ap.add_argument("--uboot-patch", type=Path, help="U-Boot patch (default: 403-add-gemtek-xr1710g.patch)")
    ap.add_argument("--uboot-makefile", type=Path, help="uboot-airoha Makefile")
    ap.add_argument("--envtools", type=Path, help="uboot-envtools airoha_an7581 script")
    ap.add_argument("--dts", type=Path, action="append", help="board DTS/DTSI (auto-follows #include)")
    args = ap.parse_args(argv)
    repo = args.repo.resolve()
    patch_p = args.uboot_patch or repo / "package/boot/uboot-airoha/patches/403-add-gemtek-xr1710g.patch"
    mk_p = args.uboot_makefile or repo / "package/boot/uboot-airoha/Makefile"
    env_p = args.envtools or repo / "package/boot/uboot-tools/uboot-envtools/files/airoha_an7581"
    dts_ps = args.dts or [repo / "target/linux/airoha/dts/an7581-gemtek_xr1710g-ubi.dts"]

    try:
        by_file = validate_and_split_patch(patch_p.read_text(encoding="utf-8"))
        mk_txt, envtools_txt = mk_p.read_text(encoding="utf-8"), env_p.read_text(encoding="utf-8")
        dts_vols, visited_dts = collect_dts_volumes(dts_ps)
        env_lines = [ln.strip() for k, v in by_file.items() if "defenvs/" in k for ln in v]
        refs = parse_env_ubi_volumes(env_lines)
    except (OSError, PatchError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    defcfg = [ln.strip() for k, v in by_file.items() if "configs/" in k for ln in v]
    env_kv = dict(ln.split("=", 1) for ln in env_lines if "=" in ln and not ln.startswith("#"))
    cfg_kv = dict(ln.split("=", 1) for ln in defcfg if "=" in ln and not ln.startswith("#"))
    fails: list[str] = []
    if not refs:
        fails.append("no 'ubi check'/'ubi read' commands found in U-Boot defenv")
    if missing := sorted({v for _, v in refs} - (dts_vols | RUNTIME_UBI_VOLUMES)):
        fails.append(f"UBI volumes absent from DTS ({', '.join(p.name for p in visited_dts)}): {', '.join(missing)}")
    for k, want, src in (("CONFIG_SYS_LOAD_ADDR", "0x85000000", cfg_kv), ("loadaddr", "0x85000000", env_kv), ("CONFIG_ENV_SIZE", "0x4000", cfg_kv)):
        if src.get(k, "").lower() != want:
            fails.append(f"{k}={src.get(k)!r} != {want!r}")
    if env_kv.get("bootcmd") != "run boot_ubi":
        fails.append(f"defenv bootcmd={env_kv.get('bootcmd')!r} != 'run boot_ubi'")
    if "run bootcmd" not in env_kv.get("bootmenu_0", ""):
        fails.append(f"defenv bootmenu_0={env_kv.get('bootmenu_0')!r} does not invoke 'run bootcmd'")
    if "# CONFIG_MMC is not set" not in defcfg:
        fails.append("defconfig missing '# CONFIG_MMC is not set'")
    fails.extend(
        f"forbidden {b}=y in defconfig"
        for b in ("CONFIG_MMC", "CONFIG_ENV_IS_IN_MMC", "CONFIG_MEASURED_BOOT", "CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT")
        if cfg_kv.get(b) == "y"
    )
    if et_err := check_envtools(envtools_txt, "0x4000"):
        fails.append(f"uboot-envtools ({env_p.name}): {et_err}")
    fails.extend(f"uboot-airoha/Makefile: {e}" for e in check_uboot_makefile(mk_txt))
    if fails:
        for f in fails:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print(f"OK: U-Boot hunks, UBI volumes ({', '.join(sorted({v for _, v in refs}))}), env 0x4000, loadaddr 0x85000000, and KASLR guards verified")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
