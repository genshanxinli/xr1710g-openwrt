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
EXPECTED_PARTS = [
    ("vendor", 0x0, 0x600000, True),
    ("chainloader", 0x600000, 0x100000, True),
    ("ubi", 0x700000, 0x1B700000, False),
    ("reserved_bmt", 0x1BE00000, 0x4200000, True),
]
KASLR_REQ = ("CONFIG_DM_RNG=y", "CONFIG_RNG_AIROHA=y")
KASLR_FORBID = ("CONFIG_MEASURED_BOOT=y", "CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT=y")
KERNEL_KASLR_REQ = (
    "CONFIG_RANDOMIZE_BASE=y",
    "CONFIG_RANDOMIZE_MODULE_REGION_FULL=y",
    "CONFIG_RELOCATABLE=y",
)
ETH_RX_RESET_PATCH = "118-net-airoha_eth-reset-rx-ring-head-on-eth-init.patch"
LWIP_TX_PATCH = "404-net-lwip-linearize-chained-pbuf-in-net_lwip_tx.patch"
HTTPD_PATCH = "405-net-lwip-add-ram-only-httpd-recovery-command.patch"
C_STRIP_RE = re.compile(
    r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
    re.DOTALL,
)
BOOT_HTTPD_FORBID_RE = re.compile(
    r"\b(?:ubi\w*|mtd\w*|nand\w*|sf|saveenv|flash\w*|mmc\w*|erase|_init_env)\b|\benv\s+save\b",
    re.IGNORECASE,
)
HTTPD_FORBID_RE = re.compile(
    r"\b(?:ubi_\w*|mtd_\w*|nand_\w*|spi_flash_\w*|sf_\w*"
    r"|env_save\w*|saveenv|blk_dwrite|blk_derase"
    r"|do_ubi|do_mtd|do_nand|do_sf|do_saveenv)\b"
)
HTTPD_REQ_SYMS = (
    "disable_ctrlc",
    "lmb_read_check",
    "fit_check_format",
    "tcp_abort",
    "SOF_REUSEADDR",
    "udp_sendto_if_src",
    "led_get_by_label",
    "EVT_POST_PREBOOT",
)


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
        text = _strip_dts_comments(path.read_text(encoding="utf-8"))
        visited.append(path)
        vols.update(VOLNAME_RE.findall(text))
        for inc in INCLUDE_RE.findall(text):
            if (path.parent / inc).is_file():
                walk(path.parent / inc)

    for p in paths:
        walk(p)
    return vols, visited


def _strip_dts_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def _extract_brace_body(text: str, open_idx: int) -> tuple[str, int]:
    depth = 0
    for idx in range(open_idx, len(text)):
        ch = text[idx]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1 : idx], idx + 1
    raise PatchError("unterminated '{' block in DTS")


def parse_fixed_partitions(text: str) -> list[tuple[str, int, int, bool]]:
    clean = _strip_dts_comments(text)
    for m in re.finditer(r"\bpartitions\s*\{", clean):
        body, _ = _extract_brace_body(clean, m.end() - 1)
        if not re.search(r'compatible\s*=\s*"fixed-partitions"\s*;', body):
            continue
        parts: list[tuple[str, int, int, bool]] = []
        pos = 0
        while pos < len(body):
            nm = re.search(r"([A-Za-z0-9_,.-]+(?:@[0-9A-Fa-f]+)?)\s*\{", body[pos:])
            if not nm:
                break
            open_pos = pos + nm.end() - 1
            node_body, next_pos = _extract_brace_body(body, open_pos)
            pos = next_pos
            top_chars: list[str] = []
            depth = 0
            for ch in node_body:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                elif depth == 0:
                    top_chars.append(ch)
            top = "".join(top_chars)
            lm = re.search(r'\blabel\s*=\s*"([^"]+)"\s*;', top)
            rm = re.search(r"\breg\s*=\s*<\s*([^\s>]+)\s+([^\s>]+)\s*>\s*;", top)
            if not lm or not rm:
                raise PatchError(f"fixed-partitions node {nm.group(1)!r} missing label or reg")
            try:
                off, sz = int(rm.group(1), 0), int(rm.group(2), 0)
            except ValueError as exc:
                raise PatchError(f"fixed-partitions node {nm.group(1)!r} invalid reg: {exc}") from exc
            ro = bool(re.search(r"(?:^|;)\s*read-only\s*;", top))
            parts.append((lm.group(1), off, sz, ro))
        return parts
    return []


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


def check_boot_httpd(env_kv: dict[str, str]) -> list[str]:
    boot_httpd = env_kv.get("boot_httpd", "").strip()
    if not boot_httpd:
        return ["defenv missing boot_httpd"]
    errs: list[str] = []
    has_httpd = False
    queue = [boot_httpd]
    seen: set[str] = set()
    hits: list[str] = []
    while queue:
        expr = queue.pop(0)
        hits.extend(m.group(0) for m in BOOT_HTTPD_FORBID_RE.finditer(expr))
        for cmd in CMD_SEP_RE.split(expr):
            t = cmd.split()
            while t and t[0] in HUSH_PREFIX:
                t = t[1:]
            if not t:
                continue
            if t[0] == "httpd":
                has_httpd = True
            elif t[0] == "run":
                for var in t[1:]:
                    if var not in seen and var in env_kv:
                        seen.add(var)
                        queue.append(env_kv[var])
    if not has_httpd:
        errs.append(f"defenv boot_httpd={boot_httpd!r} does not invoke 'httpd'")
    if hits:
        uniq = ", ".join(dict.fromkeys(hits))
        errs.append(f"defenv boot_httpd contains forbidden flash/persistence command(s): {uniq}")
    return errs


def check_httpd_c_ram_only(added_lines: list[str]) -> list[str]:
    stripped = C_STRIP_RE.sub(" ", "\n".join(added_lines))
    errs: list[str] = []
    if hits := sorted(set(HTTPD_FORBID_RE.findall(stripped))):
        errs.append(
            f"{HTTPD_PATCH} cmd/lwip/httpd.c references forbidden flash/env-persistence symbol(s): {', '.join(hits)}"
        )
    for sym in HTTPD_REQ_SYMS:
        if not re.search(rf"\b{re.escape(sym)}\b", stripped):
            errs.append(f"{HTTPD_PATCH} cmd/lwip/httpd.c missing required hardening symbol: {sym}")
    return errs


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
    ap.add_argument("--kernel-config", type=Path, help="kernel config (default: target/linux/airoha/an7581/config-7.4)")
    args = ap.parse_args(argv)
    repo = args.repo.resolve()
    patch_p = args.uboot_patch or repo / "package/boot/uboot-airoha/patches/403-add-gemtek-xr1710g.patch"
    mk_p = args.uboot_makefile or repo / "package/boot/uboot-airoha/Makefile"
    env_p = args.envtools or repo / "package/boot/uboot-tools/uboot-envtools/files/airoha_an7581"
    dts_ps = args.dts or [repo / "target/linux/airoha/dts/an7581-gemtek_xr1710g-ubi.dts"]
    kcfg_p = args.kernel_config or repo / "target/linux/airoha/an7581/config-7.4"

    try:
        by_file = validate_and_split_patch(patch_p.read_text(encoding="utf-8"))
        mk_txt, envtools_txt = mk_p.read_text(encoding="utf-8"), env_p.read_text(encoding="utf-8")
        kcfg_lines = {ln.strip() for ln in kcfg_p.read_text(encoding="utf-8").splitlines()}
        dts_vols, visited_dts = collect_dts_volumes(dts_ps)
        env_lines = [ln.strip() for k, v in by_file.items() if "defenvs/" in k for ln in v]
        refs = parse_env_ubi_volumes(env_lines)
    except (OSError, PatchError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    defcfg = [ln.strip() for k, v in by_file.items() if "configs/" in k for ln in v]
    uboot_dts_txt = "\n".join(ln for k, v in by_file.items() if k.endswith(".dts") for ln in v)
    env_kv = dict(ln.split("=", 1) for ln in env_lines if "=" in ln and not ln.startswith("#"))
    cfg_kv = dict(ln.split("=", 1) for ln in defcfg if "=" in ln and not ln.startswith("#"))
    fails: list[str] = []
    if not refs:
        fails.append("no 'ubi check'/'ubi read' commands found in U-Boot defenv")
    if missing := sorted({v for _, v in refs} - (dts_vols | RUNTIME_UBI_VOLUMES)):
        fails.append(f"UBI volumes absent from DTS ({', '.join(p.name for p in visited_dts)}): {', '.join(missing)}")
    for k, want, src in (
        ("CONFIG_SYS_LOAD_ADDR", "0x85000000", cfg_kv),
        ("loadaddr", "0x85000000", env_kv),
        ("initaddr", "0x89000000", env_kv),
        ("CONFIG_ENV_SIZE", "0x4000", cfg_kv),
        ("CONFIG_ENV_IS_IN_UBI", "y", cfg_kv),
        ("CONFIG_ENV_REDUNDANT", "y", cfg_kv),
        ("CONFIG_ENV_UBI_PART", '"ubi"', cfg_kv),
        ("CONFIG_ENV_UBI_VOLUME", '"ubootenv"', cfg_kv),
        ("CONFIG_ENV_UBI_VOLUME_REDUND", '"ubootenv2"', cfg_kv),
        ("CONFIG_NET_LWIP", "y", cfg_kv),
        ("CONFIG_CMD_HTTPD", "y", cfg_kv),
        ("CONFIG_CMD_BUTTON", "y", cfg_kv),
        ("CONFIG_LWIP_TCP_WND", "65535", cfg_kv),
    ):
        if src.get(k, "").lower() != want:
            fails.append(f"{k}={src.get(k)!r} != {want!r}")
    netmask = env_kv.get("netmask", "").strip()
    if not re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", netmask):
        fails.append(f"defenv netmask={env_kv.get('netmask')!r} missing or invalid IPv4 mask")
    fails.extend(check_boot_httpd(env_kv))
    for env_vol_k in ("CONFIG_ENV_UBI_VOLUME", "CONFIG_ENV_UBI_VOLUME_REDUND"):
        vname = cfg_kv.get(env_vol_k, "").strip('"')
        if vname and vname not in dts_vols:
            fails.append(f"{env_vol_k}={vname!r} absent from kernel DTS UBI volumes")
    try:
        uboot_parts = parse_fixed_partitions(uboot_dts_txt)
        kernel_parts: list[tuple[str, int, int, bool]] = []
        for dp in visited_dts:
            if found := parse_fixed_partitions(dp.read_text(encoding="utf-8")):
                kernel_parts = found
                break
    except PatchError as exc:
        fails.append(f"fixed-partitions parse error: {exc}")
        uboot_parts, kernel_parts = [], []
    if not uboot_parts:
        fails.append("U-Boot DTS missing fixed-partitions table")
    elif uboot_parts != EXPECTED_PARTS:
        fails.append(f"U-Boot DTS fixed-partitions {uboot_parts!r} != expected {EXPECTED_PARTS!r}")
    if not kernel_parts:
        fails.append(f"kernel DTS ({', '.join(p.name for p in visited_dts)}) missing fixed-partitions table")
    elif kernel_parts != EXPECTED_PARTS:
        fails.append(f"kernel DTS fixed-partitions {kernel_parts!r} != expected {EXPECTED_PARTS!r}")
    if uboot_parts and kernel_parts and uboot_parts != kernel_parts:
        fails.append(f"fixed-partitions mismatch: u-boot={uboot_parts!r} != kernel={kernel_parts!r}")
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
    fails.extend(f"kernel config ({kcfg_p.name}) missing {sym}" for sym in KERNEL_KASLR_REQ if sym not in kcfg_lines)
    uboot_patch_dir = repo / "package/boot/uboot-airoha/patches"
    rng_patches = sorted(uboot_patch_dir.glob("*rng-airoha*.patch"))
    if not rng_patches:
        fails.append("package/boot/uboot-airoha/patches/ missing *rng-airoha*.patch")
    p118 = uboot_patch_dir / ETH_RX_RESET_PATCH
    if not p118.is_file():
        fails.append(f"package/boot/uboot-airoha/patches/ missing {ETH_RX_RESET_PATCH}")
    else:
        try:
            f118 = validate_and_split_patch(p118.read_text(encoding="utf-8"))
        except (OSError, PatchError) as exc:
            fails.append(f"{ETH_RX_RESET_PATCH}: {exc}")
        else:
            eth_118 = f118.get("drivers/net/airoha_eth.c")
            if not eth_118:
                fails.append(f"{ETH_RX_RESET_PATCH}: missing added lines for drivers/net/airoha_eth.c")
            else:
                eth_clean = C_STRIP_RE.sub(" ", "\n".join(eth_118))
                for sym in ("REG_RX_CPU_IDX", "REG_RX_DMA_IDX"):
                    if not re.search(rf"\b{re.escape(sym)}\b", eth_clean):
                        fails.append(f"{ETH_RX_RESET_PATCH}: drivers/net/airoha_eth.c missing {sym}")
    p404 = uboot_patch_dir / LWIP_TX_PATCH
    if not p404.is_file():
        fails.append(f"package/boot/uboot-airoha/patches/ missing {LWIP_TX_PATCH}")
    else:
        try:
            f404 = validate_and_split_patch(p404.read_text(encoding="utf-8"))
        except (OSError, PatchError) as exc:
            fails.append(f"{LWIP_TX_PATCH}: {exc}")
        else:
            if not f404.get("net/lwip/net-lwip.c"):
                fails.append(f"{LWIP_TX_PATCH}: missing added lines for net/lwip/net-lwip.c")
    p405 = uboot_patch_dir / HTTPD_PATCH
    if not p405.is_file():
        fails.append(f"package/boot/uboot-airoha/patches/ missing {HTTPD_PATCH}")
    else:
        try:
            f405 = validate_and_split_patch(p405.read_text(encoding="utf-8"))
        except (OSError, PatchError) as exc:
            fails.append(f"{HTTPD_PATCH}: {exc}")
        else:
            kcfg_405 = f405.get("cmd/Kconfig")
            if not kcfg_405 or not any(
                re.search(r"^\s*select\s+PROT_UDP_LWIP\b", ln) for ln in kcfg_405
            ):
                fails.append(f"{HTTPD_PATCH}: cmd/Kconfig missing 'select PROT_UDP_LWIP'")
            lwipopts_405 = f405.get("lib/lwip/u-boot/lwipopts.h")
            lwipopts_clean = C_STRIP_RE.sub(" ", "\n".join(lwipopts_405)) if lwipopts_405 else ""
            if not re.search(r"(?m)^\s*#\s*define\s+LWIP_IP_ACCEPT_UDP_PORT\b", lwipopts_clean):
                fails.append(
                    f"{HTTPD_PATCH}: lib/lwip/u-boot/lwipopts.h missing 'LWIP_IP_ACCEPT_UDP_PORT'"
                )
            if not re.search(r"(?m)^\s*#\s*define\s+SO_REUSE\s+1\b", lwipopts_clean):
                fails.append(
                    f"{HTTPD_PATCH}: lib/lwip/u-boot/lwipopts.h missing '#define SO_REUSE 1'"
                )
            httpd_lines = f405.get("cmd/lwip/httpd.c")
            if not httpd_lines:
                fails.append(f"{HTTPD_PATCH}: missing added lines for cmd/lwip/httpd.c")
            else:
                fails.extend(check_httpd_c_ram_only(httpd_lines))
    if fails:
        for f in fails:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print(
        f"OK: U-Boot hunks (118/403/404/405), fixed-partitions ({', '.join(p[0] for p in uboot_parts)}), "
        f"UBI volumes ({', '.join(sorted({v for _, v in refs}))}), env 0x4000, loadaddr 0x85000000, "
        f"RAM-only HTTP recovery, and KASLR guards verified"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
