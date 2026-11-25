#!/usr/bin/env python3
"""Offline checks for scripts/claims-verify.py against throwaway fixtures.

The verifier's job is to fail a claim whose CONTENT moved while its bookkeeping
stayed valid.  These tests build a miniature repository in a temp directory
(fake .config, fake artifact, fake patch, fake device path string), so nothing
here needs a real build tree, the box, or the network.

The regression case is test_stale_content_fails_where_format_passes: a ledger
row with every field in place and ``status: supported`` whose cited line no
longer says what the row claims.  scripts/check-claims.py passes it (that is
exactly the hole this work closes) and ClaimsVerify must fail it.

Run from the repository root:

    python3 -m unittest scripts/tests/test_claims_verify.py
"""

import contextlib
import io
import importlib.util
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _load(name: str):
    path = REPO_ROOT / "scripts" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


claims_check = _load("check-claims.py")
claims_verify = _load("claims-verify.py")


LEDGER_HEAD = "claims:\n"


def ledger(*records: str) -> str:
    # Records are written with their own indentation; do not dedent them away.
    return LEDGER_HEAD + "\n".join(record.strip("\n") for record in records)


def record(claim_id: str, source: str, verify: list[str] | None = None,
           status: str = "supported", extra: list[str] | None = None) -> str:
    lines = [
        f"  - id: {claim_id}",
        '    claim: "one line about the content"',
        "    source:",
        f'      - "{source}"',
    ]
    if verify:
        lines.append("    verify:")
        for item in verify:
            lines.append(f'      - "{item}"')
    lines += [
        "    evidence: 实测",
        '    date: "2026-11-20"',
        f"    status: {status}",
        '    notes: "fixture row"',
    ]
    if extra:
        lines.extend(extra)
    return "\n".join(lines) + "\n"


def run_verify(root: Path, text: str, *args: str) -> tuple[int, str]:
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as handle:
        handle.write(text)
        ledger_path = Path(handle.name)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = claims_verify.main(
                ["--ledger", str(ledger_path), "--root", str(root), *args]
            )
    finally:
        ledger_path.unlink()
    return code, out.getvalue()


def run_check(text: str, root: Path) -> tuple[int, str]:
    # check-claims.py resolves sources against its module-level REPO_ROOT, so
    # point it at the fixture tree for the run and put it back afterwards.
    saved = claims_check.REPO_ROOT
    claims_check.REPO_ROOT = root
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as handle:
        handle.write(text)
        ledger_path = Path(handle.name)
    out = io.StringIO()
    try:
        with contextlib.redirect_stderr(out), contextlib.redirect_stdout(out):
            code = claims_check.main(["--ledger", str(ledger_path)])
    finally:
        ledger_path.unlink()
        claims_check.REPO_ROOT = saved
    return code, out.getvalue()


class FixtureRoot:
    """A temp tree that looks like the repo to the verifier."""

    def __init__(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def write(self, relative: str, content: str | bytes) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
        return path

    def close(self) -> None:
        self._tmp.cleanup()


class ConfigClassTest(unittest.TestCase):
    """A class: a Kconfig value in a shipped config."""

    def setUp(self) -> None:
        self.fixture = FixtureRoot()
        self.addCleanup(self.fixture.close)

    def test_matching_value_passes(self) -> None:
        self.fixture.write("target/linux/airoha/an7581/config-7.3", "CONFIG_FOO=y\n")
        text = ledger(record("cfg-ok", "target/linux/airoha/an7581/config-7.3:1",
                             ["kconfig: target/linux/airoha/an7581/config-7.3 CONFIG_FOO=y"]))
        code, out = run_verify(self.fixture.root, text)
        self.assertEqual(code, 0, out)
        self.assertIn("cfg-ok PASS", out)

    def test_mismatched_value_fails(self) -> None:
        self.fixture.write("target/linux/airoha/an7581/config-7.3", "CONFIG_FOO=y\n")
        text = ledger(record("cfg-bad", "target/linux/airoha/an7581/config-7.3:1",
                             ["kconfig: target/linux/airoha/an7581/config-7.3 CONFIG_BAR=y"]))
        code, out = run_verify(self.fixture.root, text)
        self.assertIn("cfg-bad FAIL", out)
        self.assertIn("verified=0 failed=1 skipped=0", out)

    def test_not_set_line_counts_as_n(self) -> None:
        self.fixture.write("target/linux/airoha/an7581/config-7.3",
                           "# CONFIG_FOO is not set\n")
        text = ledger(record("cfg-unset", "target/linux/airoha/an7581/config-7.3:1",
                             ["kconfig: target/linux/airoha/an7581/config-7.3 CONFIG_FOO=n"]))
        code, out = run_verify(self.fixture.root, text)
        self.assertIn("cfg-unset PASS", out)

    def test_glob_without_match_skips_not_fails(self) -> None:
        text = ledger(record("cfg-nobuild", "README.md:1",
                             ["kconfig: build_dir/**/linux-7.4-rc3/.config CONFIG_TRACEPOINTS=y"]))
        self.fixture.write("README.md", "text\n")
        code, out = run_verify(self.fixture.root, text, "--skip", "source")
        self.assertIn("cfg-nobuild SKIP", out)
        self.assertIn("verified=0 failed=0 skipped=1", out)


class SymbolClassTest(unittest.TestCase):
    """B class: a symbol inside a built artifact."""

    def setUp(self) -> None:
        self.fixture = FixtureRoot()
        self.addCleanup(self.fixture.close)

    def test_symbol_present_passes(self) -> None:
        self.fixture.write("build_dir/x/nf_flow_table_ip.o", b"\x00nf_flow_pppoe\x00")
        text = ledger(record("sym-ok", "scripts/x.sh:1",
                             ["symbol: build_dir/**/nf_flow_table_ip.o nf_flow_pppoe"]))
        self.fixture.write("scripts/x.sh", "#\n")
        code, out = run_verify(self.fixture.root, text)
        self.assertIn("sym-ok PASS", out)

    def test_symbol_absent_fails(self) -> None:
        self.fixture.write("build_dir/x/nf_flow_table_ip.o", b"\x00something_else\x00")
        text = ledger(record("sym-gone", "scripts/x.sh:1",
                             ["symbol: build_dir/**/nf_flow_table_ip.o nf_flow_pppoe"]))
        self.fixture.write("scripts/x.sh", "#\n")
        code, out = run_verify(self.fixture.root, text)
        self.assertIn("sym-gone FAIL", out)
        self.assertIn("verified=0 failed=1 skipped=0", out)


class TextClassTest(unittest.TestCase):
    """C class: path:line holds an exact substring."""

    def setUp(self) -> None:
        self.fixture = FixtureRoot()
        self.addCleanup(self.fixture.close)

    def test_missing_path_fails(self) -> None:
        text = ledger(record("txt-missing", "docs/gone.md:3",
                             ["text: docs/gone.md:3 anything"]))
        code, out = run_verify(self.fixture.root, text)
        self.assertIn("txt-missing FAIL", out)
        self.assertIn("path missing", out)

    def test_substring_is_literal_not_regex(self) -> None:
        self.fixture.write("README.md", "module only handles UDP\n")
        text = ledger(record("txt-regex", "README.md:1",
                             ["text: README.md:1 module only.*UDP"]))
        code, out = run_verify(self.fixture.root, text)
        self.assertIn("txt-regex FAIL", out)


class RegressionTest(unittest.TestCase):
    """The hole this work closes: format green, content stale."""

    def setUp(self) -> None:
        self.fixture = FixtureRoot()
        self.addCleanup(self.fixture.close)

    def test_stale_content_fails_where_format_passes(self) -> None:
        self.fixture.write("target/linux/airoha/patches-7.3/210.patch",
                           "-\t*index = hash - PPE_STATS_NUM_ENTRIES\n"
                           "+-# CONFIG_FTRACE is not set\n")
        text = ledger(record(
            "stale-fix",
            "target/linux/airoha/patches-7.3/210.patch:2",
            ["text: target/linux/airoha/patches-7.3/210.patch:2 if (hash >= ppe_num_stats_entries)"],
        ))
        check_code, check_out = run_check(text, self.fixture.root)
        self.assertEqual(check_code, 0, f"the old checker should still be happy:\n{check_out}")

        code, out = run_verify(self.fixture.root, text, "--strict")
        self.assertEqual(code, 1, out)
        self.assertIn("stale-fix FAIL", out)
        self.assertIn("verified=0 failed=1 skipped=0", out)

    def test_supported_without_hook_is_rejected_by_checker(self) -> None:
        text = ledger(record("no-hook", "README.md:1"))
        self.fixture.write("README.md", "text\n")
        code, out = run_check(text, self.fixture.root)
        self.assertEqual(code, 1, out)
        self.assertIn("needs a hook", out)

    def test_manual_row_needs_verified_at(self) -> None:
        text = ledger(record("manual-no-sha", "README.md:1",
                             extra=["    manual: true"]))
        self.fixture.write("README.md", "text\n")
        code, out = run_check(text, self.fixture.root)
        self.assertEqual(code, 1, out)
        self.assertIn("manual: true needs verified_at", out)

    def test_manual_row_with_sha_passes_both(self) -> None:
        text = ledger(record("manual-ok", "README.md:1",
                             extra=["    manual: true", "    verified_at: a86ce12e27"]))
        self.fixture.write("README.md", "text\n")
        self.assertEqual(run_check(text, self.fixture.root)[0], 0)
        code, out = run_verify(self.fixture.root, text)
        self.assertIn("manual-ok PASS", out)


class SkipAndSummaryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = FixtureRoot()
        self.addCleanup(self.fixture.close)

    def test_skip_class_reports_skip_not_fail(self) -> None:
        self.fixture.write("README.md", "text\n")
        text = ledger(record("txt-skipped", "README.md:1",
                             ["text: README.md:1 absent substring"]))
        code, out = run_verify(self.fixture.root, text, "--skip", "text,source")
        self.assertEqual(code, 0, out)
        self.assertIn("class text skipped", out)
        self.assertIn("verified=0 failed=0 skipped=1", out)

    def test_repeated_skip_flags_union_instead_of_overwriting(self) -> None:
        # r28 CI-13: the usage block spelled the CI command as
        # `--skip device --skip symbol`.  argparse's default action keeps only
        # the last value, so that spelling skipped one class and silently left
        # the other live.  Both spellings must skip the same classes.
        self.fixture.write("README.md", "text\n")
        text = ledger(
            record("txt-1", "README.md:1", ["text: README.md:1 absent substring"]),
            record("dev-1", "README.md:1", [
                "device: /sys/class/watchdog/watchdog0/min_timeout 28"]),
        )
        code, repeated = run_verify(
            self.fixture.root, text, "--skip", "text", "--skip", "device")
        self.assertEqual(code, 0, repeated)
        self.assertNotIn("FAIL", repeated)
        for cls in ("text", "device"):
            self.assertIn("class %s skipped" % cls, repeated)

        code, comma = run_verify(self.fixture.root, text, "--skip", "text,device")
        self.assertEqual(code, 0, comma)
        self.assertEqual(comma.splitlines()[-1], repeated.splitlines()[-1])

    def test_unknown_skip_class_is_a_usage_error(self) -> None:
        with self.assertRaises(SystemExit):
            run_verify(self.fixture.root, ledger(record("x", "README.md:1")), "--skip", "banana")

    def test_dry_run_lists_plan_and_touches_nothing(self) -> None:
        text = ledger(record("dev-dry", "README.md:1", [
            "device: /sys/class/watchdog/watchdog0/min_timeout 28",
            "text: README.md:1 text",
        ]))
        self.fixture.write("README.md", "text\n")
        code, out = run_verify(self.fixture.root, text, "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("dev-dry DRY", out)
        self.assertIn("verified=0 failed=0 skipped=0", out)


class NeedsReverifyTest(unittest.TestCase):
    """verified_at..HEAD touching a cited path warns (not fails) today."""

    def setUp(self) -> None:
        self.fixture = FixtureRoot()
        self.addCleanup(self.fixture.close)

    def _git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(self.fixture.root), *args],
            capture_output=True, text=True, check=True,
        ).stdout.strip()

    def test_changed_cited_path_warns_only(self) -> None:
        self.fixture.write("scripts/foo.sh", "# v1\n")
        self._git("init", "-q")
        self._git("config", "user.email", "t@example.invalid")
        self._git("config", "user.name", "t")
        self._git("add", "-A")
        self._git("commit", "-qm", "first")
        sha = self._git("rev-parse", "--short", "HEAD")

        text = ledger(record("drifted", "scripts/foo.sh:1",
                             extra=["    manual: true", f"    verified_at: {sha}"]))

        self.fixture.write("scripts/foo.sh", "# v2\n")
        self._git("commit", "-qam", "second")

        code, out = run_verify(self.fixture.root, text)
        self.assertEqual(code, 0, out)
        self.assertIn("needs-reverify", out)

    def test_verify_hook_suppresses_the_warning(self) -> None:
        self.fixture.write("scripts/foo.sh", "# v1\n")
        self._git("init", "-q")
        self._git("config", "user.email", "t@example.invalid")
        self._git("config", "user.name", "t")
        self._git("add", "-A")
        self._git("commit", "-qm", "first")
        sha = self._git("rev-parse", "--short", "HEAD")

        text = ledger(record("hooked", "scripts/foo.sh:1",
                             ["text: scripts/foo.sh:1 # v1"],
                             extra=["    manual: true", f"    verified_at: {sha}"]))
        self.fixture.write("scripts/foo.sh", "# v2\n")
        self._git("commit", "-qam", "second")

        code, out = run_verify(self.fixture.root, text)
        self.assertEqual(code, 0, out)
        self.assertNotIn("needs-reverify", out)


if __name__ == "__main__":
    unittest.main()
