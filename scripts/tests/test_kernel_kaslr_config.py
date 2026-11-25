#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Kernel hardening config and the U-Boot KASLR-seed chain are pinned.

Three issues land in two files, and every one of them is a one-line edit that
a later fragment merge (or a well-meaning cleanup) can silently undo:

  * #373 -- `arch/arm64` builds `kaslr_early`/`kaslr` only under
    `CONFIG_RANDOMIZE_BASE`.  The generic fragment pins it off, so the
    `an7581` fragment must override it; `RANDOMIZE_MODULE_REGION_FULL` is
    written out explicitly so the `0 pages in range for non-PLT usage`
    boot signature stays an assertable baseline.
  * #377 -- `PERF_EVENTS` must override the generic `is not set` line; without
    it the `ARM_PMUV3` PMU node has no subsystem behind it.
  * #383 -- soft-lockup and hung-task detectors, with the hung-task threshold
    below the 28 s SoC watchdog (15 s), so the detector actually reports
    before the board resets.

`Kernel/Configure/Default` merges in three steps, and step 1 is not the one
that ships: (1) generic + target fragments through `scripts/kconfig.pl`;
(2) the top-level `.config`'s `CONFIG_KERNEL_*` lines, renamed to
`CONFIG_*`, appended *after* the fragments; (3) `kconfig.pl 'm+' '+'` with
the package override.  The last line wins, so a stale
`# CONFIG_KERNEL_FOO is not set` silently flips a fragment's
`CONFIG_FOO=y` back off.  `.config` is untracked (`.gitignore:6`); a fresh
`make defconfig` writes the `CONFIG_KERNEL_*` mirror of
`config/Config-kernel.in`, which is why the tracked defaults asserted here
decide the final `.config.set`.

U-Boot half of #373: `boot/fdt_support.c fdt_kaslrseed()` is a no-op unless
`CONFIG_DM_RNG` and the `RNG_AIROHA` driver are built, and it is suppressed
outright by `MEASURED_BOOT`/`ARMV8_SEC_FIRMWARE_SUPPORT`.  Because
`include/u-boot.mk` wires `Build/Configure` through
`$(eval $(call Build/DefaultTargets))`, Make expands `Build/Configure` twice
(once during `call`, once when executing the recipe): a shell `for sym` with
`$$sym` collapses to `$sym` -> `$(s)ym` -> `ym` (`CONFIG_ym`).  `Build/Configure`
must therefore assert all four symbols literally without shell-variable
double-expansion hazards, and the test runs real `make` through the same
`$(eval $(call Build/DefaultTargets))` expansion path.

The files under test are injected through `*_UNDER_TEST` environment
variables, so the red half can point at unmodified copies:

    KERNEL_CONFIG_7_4_UNDER_TEST=/tmp/copy/config-7.4 \\
    CONFIG_KERNEL_IN_UNDER_TEST=/tmp/copy/Config-kernel.in \\
    TOPDIR_CONFIG_UNDER_TEST=/tmp/copy/.config \\
    UBOOT_AIROHA_MAKEFILE_UNDER_TEST=/tmp/copy/Makefile \\
        python3 -m unittest scripts.tests.test_kernel_kaslr_config -v

Run from the repository root:

    python3 -m unittest scripts.tests.test_kernel_kaslr_config -v
"""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG = Path(
    os.environ.get(
        "KERNEL_CONFIG_7_4_UNDER_TEST",
        REPO_ROOT / "target/linux/airoha/an7581/config-7.4",
    )
).resolve()
UBOOT_MAKEFILE = Path(
    os.environ.get(
        "UBOOT_AIROHA_MAKEFILE_UNDER_TEST",
        REPO_ROOT / "package/boot/uboot-airoha/Makefile",
    )
).resolve()
GENERIC_CONFIG = REPO_ROOT / "target/linux/generic/config-7.4"
KCONFIG_PL = REPO_ROOT / "scripts/kconfig.pl"
CONFIG_KERNEL_IN = Path(
    os.environ.get(
        "CONFIG_KERNEL_IN_UNDER_TEST",
        REPO_ROOT / "config/Config-kernel.in",
    )
).resolve()
TOPDIR_CONFIG_UNDER_TEST = os.environ.get("TOPDIR_CONFIG_UNDER_TEST")
# Built by `make defconfig`; a clean clone has no build product, hence the
# skip guard on DefconfigProjectionTest.
CONFIG_CONF = REPO_ROOT / "scripts/config/conf"

# What a fresh `make defconfig` writes into the untracked top-level `.config`
# once the tracked airoha defaults land.  This checkout's `.config` cannot be
# read here: it is untracked, still holds the pre-fix `is not set` lines, and
# `make defconfig` re-reads an existing `.config` as the defconfig input, so
# those explicit user values survive it.  Only a fresh tree/clone (or a
# deleted `.config`) projects the defaults.  The `y` lines below come from a
# measured `conf --defconfig=<empty>` run (2026-11-25, review r_p1fixes sec.4);
# this fixture feeds steps 2 and 3 of Kernel/Configure/Default, while
# DefconfigProjectionTest runs the real projection.
DEFCONFIG_TOPDIR = """\
CONFIG_TARGET_airoha=y
CONFIG_KERNEL_PERF_EVENTS=y
CONFIG_KERNEL_SOFTLOCKUP_DETECTOR=y
CONFIG_KERNEL_HARDLOCKUP_DETECTOR=y
CONFIG_KERNEL_DETECT_HUNG_TASK=y
"""

# `CONFIG_FOO=y` and `# CONFIG_FOO is not set`, in file order.
CONFIG_LINE = re.compile(r"^(?:# )?(CONFIG_[A-Za-z0-9_]+)(?:=| is not set)")
BUILD_CONFIGURE = re.compile(
    r"^define Build/Configure\n(.*?)^endef$", re.DOTALL | re.MULTILINE
)


def parse_fragment(text):
    """Return (ordered symbols, value map) for a kernel config fragment."""
    symbols = []
    values = {}
    for line in text.splitlines():
        match = CONFIG_LINE.match(line)
        if not match:
            continue
        symbol = match.group(1)
        symbols.append(symbol)
        if line.startswith("# "):
            values[symbol] = None
        else:
            values[symbol] = line.split("=", 1)[1]
    return symbols, values


def kconfig_block(text, symbol):
    """Return the body of a `config <symbol>` block from a Kconfig file."""
    match = re.search(
        rf"^config {re.escape(symbol)}\n(.*?)(?=^config |\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"config {symbol} not found in {CONFIG_KERNEL_IN}")
    return match.group(1)


class KernelConfigHardeningTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = CONFIG.read_text()
        cls.lines = [line.strip() for line in cls.text.splitlines()]
        cls.symbols, cls.values = parse_fragment(cls.text)

    def assert_enabled(self, symbol):
        self.assertEqual(
            self.values.get(symbol),
            "y",
            f"{symbol} must be enabled in {CONFIG}, got {self.values.get(symbol)!r}",
        )

    def assert_dictionary_order(self, symbol):
        """The fragment is kept sorted by symbol name; a new line must fit."""
        self.assertIn(symbol, self.symbols)
        index = self.symbols.index(symbol)
        neighbours = [
            name
            for name in (
                self.symbols[index - 1] if index else None,
                symbol,
                self.symbols[index + 1] if index + 1 < len(self.symbols) else None,
            )
            if name is not None
        ]
        self.assertEqual(
            neighbours,
            sorted(neighbours),
            f"{symbol} is not in dictionary order: {neighbours}",
        )

    def test_kaslr_enabled(self):
        for symbol in (
            "CONFIG_RANDOMIZE_BASE",
            "CONFIG_RANDOMIZE_MODULE_REGION_FULL",
        ):
            with self.subTest(symbol=symbol):
                self.assertNotIn(f"# {symbol} is not set", self.text)
                self.assert_enabled(symbol)

    def test_kaslr_is_inserted_in_dictionary_order(self):
        # Reviews r18 §4.1/§4.5: the pair belongs between QUEUED_SPINLOCKS and
        # RANDSTRUCT_NONE; anywhere else breaks the fragment ordering rule and
        # `make target/linux/refresh` rewrites the file around it.
        window = [
            "CONFIG_QUEUED_SPINLOCKS=y",
            "CONFIG_RANDOMIZE_BASE=y",
            "CONFIG_RANDOMIZE_MODULE_REGION_FULL=y",
            "CONFIG_RANDSTRUCT_NONE=y",
        ]
        self.assertIn(window, [self.lines[i : i + len(window)] for i in range(len(self.lines))])

    def test_perf_events_enabled(self):
        # #377: ARM_PMUV3 is already on; without PERF_EVENTS the PMU is inert.
        self.assertNotIn("# CONFIG_PERF_EVENTS is not set", self.text)
        self.assert_enabled("CONFIG_PERF_EVENTS")
        self.assert_dictionary_order("CONFIG_PERF_EVENTS")

    def test_lockup_detectors_enabled(self):
        # #383: soft/hard lockup + hung task detectors; hung task threshold
        # must fire before the 28 s SoC watchdog.
        self.assert_enabled("CONFIG_SOFTLOCKUP_DETECTOR")
        self.assert_enabled("CONFIG_HARDLOCKUP_DETECTOR")
        self.assert_enabled("CONFIG_DETECT_HUNG_TASK")
        timeout = self.values.get("CONFIG_DEFAULT_HUNG_TASK_TIMEOUT")
        self.assertIsNotNone(
            timeout,
            "CONFIG_DEFAULT_HUNG_TASK_TIMEOUT must be set explicitly",
        )
        timeout = int(timeout)
        self.assertEqual(timeout, 15)
        self.assertLess(
            timeout,
            28,
            "hung-task timeout must stay below the airoha_wdt 28 s hard reset",
        )
        for symbol in (
            "CONFIG_HARDLOCKUP_DETECTOR",
            "CONFIG_SOFTLOCKUP_DETECTOR",
            "CONFIG_DETECT_HUNG_TASK",
            "CONFIG_DEFAULT_HUNG_TASK_TIMEOUT",
        ):
            with self.subTest(symbol=symbol):
                self.assert_dictionary_order(symbol)

    def test_tickless_idle_not_overridden_by_hz_periodic(self):
        # P1-5: CONFIG_HZ_PERIODIC=y overrides CONFIG_NO_HZ_IDLE=y in Linux
        # Kconfig's tick-mode choice, forcing a 250 Hz periodic tick on all
        # idle cores.
        self.assertNotIn("CONFIG_HZ_PERIODIC=y", self.lines)
        self.assertNotEqual(self.values.get("CONFIG_HZ_PERIODIC"), "y")
        self.assert_enabled("CONFIG_NO_HZ_IDLE")
        seen = set()
        dups = []
        for sym in self.symbols:
            if sym in seen:
                dups.append(sym)
            seen.add(sym)
        self.assertEqual(dups, [], f"duplicate symbols in {CONFIG}: {dups}")

    def test_fragment_overrides_generic_at_fragment_layer(self):
        # Step 1 of 3 only.  `generic` explicitly pins all of these off
        # (#373/#377/#383), so the fragment must win this merge; the top-level
        # `.config` can still flip the result in step 2, which
        # FinalKernelConfigTest covers.
        proc = subprocess.run(
            ["perl", str(KCONFIG_PL), "+target", str(GENERIC_CONFIG), str(CONFIG)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("can't parse line", proc.stderr, proc.stderr)
        _, merged = parse_fragment(proc.stdout)
        expected = {
            "CONFIG_RANDOMIZE_BASE": "y",
            "CONFIG_RANDOMIZE_MODULE_REGION_FULL": "y",
            "CONFIG_PERF_EVENTS": "y",
            "CONFIG_SOFTLOCKUP_DETECTOR": "y",
            "CONFIG_HARDLOCKUP_DETECTOR": "y",
            "CONFIG_DETECT_HUNG_TASK": "y",
            "CONFIG_DEFAULT_HUNG_TASK_TIMEOUT": "15",
            "CONFIG_NO_HZ_IDLE": "y",
            "CONFIG_HZ_PERIODIC": None,
        }
        for symbol, value in expected.items():
            with self.subTest(symbol=symbol):
                self.assertEqual(merged.get(symbol), value)


class ConfigKernelDefaultsTest(unittest.TestCase):
    """The tracked defaults must reach a fresh top-level .config."""

    @classmethod
    def setUpClass(cls):
        cls.text = CONFIG_KERNEL_IN.read_text()

    def test_airoha_defaults_enable_hardening(self):
        for symbol in (
            "KERNEL_PERF_EVENTS",
            "KERNEL_SOFTLOCKUP_DETECTOR",
            "KERNEL_HARDLOCKUP_DETECTOR",
        ):
            with self.subTest(symbol=symbol):
                block = kconfig_block(self.text, symbol)
                self.assertIn(
                    "default y if TARGET_airoha",
                    block,
                    f"{symbol} needs a tracked default for TARGET_airoha in "
                    f"{CONFIG_KERNEL_IN}; otherwise a fresh defconfig writes "
                    f"`# CONFIG_{symbol} is not set`, and step 2 of "
                    f"Kernel/Configure/Default appends it after the an7581 "
                    f"fragment and flips it back off",
                )

    def test_hung_task_follows_softlockup(self):
        block = kconfig_block(self.text, "KERNEL_DETECT_HUNG_TASK")
        self.assertIn(
            "default KERNEL_SOFTLOCKUP_DETECTOR",
            block,
            "KERNEL_DETECT_HUNG_TASK must follow KERNEL_SOFTLOCKUP_DETECTOR",
        )
        self.assertIn("depends on KERNEL_DEBUG_KERNEL", block)

    def test_fragment_owned_symbols_have_no_topdir_twin(self):
        # CONFIG_RANDOMIZE_BASE and CONFIG_DEFAULT_HUNG_TASK_TIMEOUT are owned
        # by target/linux/airoha/an7581/config-7.4.  A KERNEL_* twin here
        # without a default would be appended in step 2 and clobber them.
        for symbol in ("KERNEL_RANDOMIZE_BASE", "KERNEL_DEFAULT_HUNG_TASK_TIMEOUT"):
            with self.subTest(symbol=symbol):
                self.assertNotIn(f"config {symbol}\n", self.text)


@unittest.skipUnless(
    CONFIG_CONF.exists(),
    "scripts/config/conf is a build product (scripts/config/.gitignore); "
    "a configured tree is required for the defconfig projection",
)
class DefconfigProjectionTest(unittest.TestCase):
    """`conf --defconfig=<empty>` must project the tracked defaults to y.

    ConfigKernelDefaultsTest only greps the Kconfig text; this test runs the
    same projection `make defconfig` performs, so removing a tracked default
    turns it red instead of leaving a hand-written fixture green.
    """

    def test_fresh_defconfig_projects_the_tracked_defaults(self):
        with tempfile.TemporaryDirectory(prefix="kaslr-defconfig-") as tmpdir:
            workdir = Path(tmpdir)
            kconfig = workdir / "Kconfig"
            defconfig = workdir / "defconfig"
            output = workdir / ".config"
            kconfig.write_text(
                "config TARGET_airoha\n"
                "\tbool\n"
                "\tdefault y\n"
                "\n"
                f'source "{CONFIG_KERNEL_IN}"\n'
            )
            defconfig.write_text("")
            env = dict(os.environ, KCONFIG_CONFIG=str(output))
            proc = subprocess.run(
                [str(CONFIG_CONF), f"--defconfig={defconfig}", str(kconfig)],
                capture_output=True,
                text=True,
                check=False,
                cwd=workdir,
                env=env,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            _, values = parse_fragment(output.read_text())
            for symbol in (
                "CONFIG_KERNEL_PERF_EVENTS",
                "CONFIG_KERNEL_SOFTLOCKUP_DETECTOR",
                "CONFIG_KERNEL_HARDLOCKUP_DETECTOR",
                "CONFIG_KERNEL_DETECT_HUNG_TASK",
            ):
                with self.subTest(symbol=symbol):
                    self.assertEqual(
                        values.get(symbol),
                        "y",
                        f"{symbol} is not y in a fresh defconfig; the tracked "
                        f"default in {CONFIG_KERNEL_IN} is missing or dead",
                    )


class FinalKernelConfigTest(unittest.TestCase):
    """Steps 2 and 3 of Kernel/Configure/Default must keep the fragment's y."""

    def test_final_config_set_keeps_hardening(self):
        with tempfile.TemporaryDirectory(prefix="kaslr-final-") as tmpdir:
            workdir = Path(tmpdir)
            merged = workdir / ".config.target"
            override = workdir / ".config.override"
            topdir = workdir / ".config"

            if TOPDIR_CONFIG_UNDER_TEST:
                topdir.write_text(Path(TOPDIR_CONFIG_UNDER_TEST).read_text())
            else:
                topdir.write_text(DEFCONFIG_TOPDIR)
            override.write_text("")

            # Step 1: $(LINUX_CONF_CMD) > .config.target
            step1 = subprocess.run(
                ["perl", str(KCONFIG_PL), "+target", str(GENERIC_CONFIG), str(CONFIG)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(step1.returncode, 0, step1.stderr)
            merged.write_text(step1.stdout)

            # Step 2: awk '/^(# )?CONFIG_KERNEL/...' $(TOPDIR)/.config >> .config.target
            step2 = subprocess.run(
                [
                    "awk",
                    '/^(#[[:space:]]+)?CONFIG_KERNEL/{sub("CONFIG_KERNEL_","CONFIG_");print}',
                    str(topdir),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(step2.returncode, 0, step2.stderr)
            with merged.open("a") as handle:
                handle.write(step2.stdout)

            # Step 3: kconfig.pl 'm+' '+' .config.target /dev/null .config.override
            step3 = subprocess.run(
                [
                    "perl",
                    str(KCONFIG_PL),
                    "m+",
                    "+",
                    str(merged),
                    "/dev/null",
                    str(override),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(step3.returncode, 0, step3.stderr)
            self.assertNotIn("can't parse line", step3.stderr, step3.stderr)
            _, final = parse_fragment(step3.stdout)

            expected = {
                "CONFIG_RANDOMIZE_BASE": "y",
                "CONFIG_PERF_EVENTS": "y",
                "CONFIG_SOFTLOCKUP_DETECTOR": "y",
                "CONFIG_HARDLOCKUP_DETECTOR": "y",
                "CONFIG_DETECT_HUNG_TASK": "y",
                "CONFIG_DEFAULT_HUNG_TASK_TIMEOUT": "15",
                "CONFIG_NO_HZ_IDLE": "y",
                "CONFIG_HZ_PERIODIC": None,
            }
            for symbol, value in expected.items():
                with self.subTest(symbol=symbol):
                    self.assertEqual(
                        final.get(symbol),
                        value,
                        f"{symbol} lost in the final .config.set",
                    )


class UbootKaslrSeedAssertionsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = UBOOT_MAKEFILE.read_text()
        match = BUILD_CONFIGURE.search(cls.text)
        cls.configure = match.group(1) if match else ""

    def _run_double_expanded_configure(self, workdir, config_text=None, *, dry_run=True):
        """Mirror include/u-boot.mk:153 -> include/package.mk Build/DefaultTargets."""
        self.assertTrue(
            self.configure, f"define Build/Configure not found in {UBOOT_MAKEFILE}"
        )
        if config_text is not None:
            (workdir / ".config").write_text(config_text, encoding="utf-8")
        harness = workdir / "Makefile"
        harness.write_text(
            f"PKG_BUILD_DIR := {workdir}\n"
            "define Build/Configure/U-Boot\n"
            "\t@true\n"
            "endef\n"
            "define Build/Configure\n"
            f"{self.configure}"
            "endef\n"
            "define Build/CoreTargets\n"
            "configure:\n"
            "\t$(Build/Configure)\n"
            "endef\n"
            "define Build/DefaultTargets\n"
            "  $(Build/CoreTargets)\n"
            "endef\n"
            "$(eval $(call Build/DefaultTargets))\n",
            encoding="utf-8",
        )
        cmd = ["make", "--no-print-directory", "-f", str(harness)]
        if dry_run:
            cmd.append("-n")
        cmd.append("configure")
        return subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=30)

    def test_kaslr_seed_options_are_enabled(self):
        start = self.text.index("UBOOT_CUSTOMIZE_CONFIG")
        end = self.text.index("\n\n", start)
        block = self.text[start:end]
        for option in ("--enable DM_RNG", "--enable RNG_AIROHA"):
            with self.subTest(option=option):
                self.assertIn(option, block)

    def test_double_expanded_configure_has_exact_symbol_greps(self):
        """Real `make -n` through $(eval $(call Build/DefaultTargets)) must not mangle symbols."""
        with tempfile.TemporaryDirectory(prefix="uboot-kaslr-make-") as tmpdir:
            proc = self._run_double_expanded_configure(Path(tmpdir), dry_run=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        expanded = proc.stdout
        self.assertNotIn(
            "CONFIG_ym",
            expanded,
            f"Make double-expansion mangled $$sym into CONFIG_ym:\n{expanded}",
        )
        self.assertNotIn(
            "$sym",
            expanded,
            f"Unexpanded shell variable $sym leaked into recipe:\n{expanded}",
        )
        for pattern in (
            "^CONFIG_DM_RNG=y",
            "^CONFIG_RNG_AIROHA=y",
            "^CONFIG_MEASURED_BOOT=y",
            "^CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT=y",
        ):
            with self.subTest(pattern=pattern):
                self.assertIn(pattern, expanded, f"missing {pattern} in:\n{expanded}")

    def test_double_expanded_configure_enforces_all_four_symbols(self):
        """Run the double-expanded Build/Configure recipe against good and broken .config files."""
        valid_config = (
            "CONFIG_TOOLS_LIBCRYPTO=y\n"
            "CONFIG_DM_RNG=y\n"
            "CONFIG_RNG_AIROHA=y\n"
            "# CONFIG_MEASURED_BOOT is not set\n"
            "# CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT is not set\n"
        )
        with tempfile.TemporaryDirectory(prefix="uboot-kaslr-run-") as tmpdir:
            workdir = Path(tmpdir)
            ok = self._run_double_expanded_configure(workdir, valid_config, dry_run=False)
            self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
            self.assertIn(
                "# CONFIG_TOOLS_LIBCRYPTO is not set",
                (workdir / ".config").read_text(encoding="utf-8"),
            )

        bad_cases = (
            ("missing_dm_rng", valid_config.replace("CONFIG_DM_RNG=y\n", ""), "CONFIG_DM_RNG"),
            ("missing_rng_airoha", valid_config.replace("CONFIG_RNG_AIROHA=y\n", ""), "CONFIG_RNG_AIROHA"),
            (
                "measured_boot_enabled",
                valid_config.replace("# CONFIG_MEASURED_BOOT is not set", "CONFIG_MEASURED_BOOT=y"),
                "CONFIG_MEASURED_BOOT",
            ),
            (
                "sec_fw_enabled",
                valid_config.replace(
                    "# CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT is not set",
                    "CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT=y",
                ),
                "CONFIG_ARMV8_SEC_FIRMWARE_SUPPORT",
            ),
        )
        for name, cfg, expected_err in bad_cases:
            with self.subTest(case=name):
                with tempfile.TemporaryDirectory(prefix=f"uboot-kaslr-{name}-") as tmpdir:
                    proc = self._run_double_expanded_configure(
                        Path(tmpdir), cfg, dry_run=False
                    )
                self.assertNotEqual(
                    proc.returncode,
                    0,
                    f"{name} unexpectedly succeeded:\n{proc.stdout}{proc.stderr}",
                )
                self.assertIn(expected_err, proc.stderr, proc.stdout + proc.stderr)
                self.assertNotIn("CONFIG_ym", proc.stderr, proc.stderr)

    def test_no_shell_var_double_expansion_in_configure(self):
        self.assertNotIn("$$sym", self.configure)
        self.assertNotIn("$$$$", self.text)


if __name__ == "__main__":
    unittest.main()
