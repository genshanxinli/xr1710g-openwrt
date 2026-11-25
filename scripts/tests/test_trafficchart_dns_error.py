#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""trafficchart-domains-update must report every downloader failure with its rc.

Reproduced on the XR1710G (2026-11-22 18:54:05 first boot, 2026-11-23 00:54:20
six hours later), both attempts identical:

    Downloading 'https://github.com/.../dlc.dat_plain.yml'
    Failed to send request: Operation not permitted

That sentence is ``uclient-fetch.c:955`` printing ``strerror(rc)`` for an
internal negative return from ``init_request()``; it is not the kernel's EPERM
and not evidence of a DNS or permission fault.  The script then tried wget and
curl through the same stderr file, so only the last attempt's text survived and
the other failure reasons were discarded.  State stayed ``status=FAILED`` /
``last_success=0`` while the rules database kept its two bootstrap rows.

What these tests assert, offline, by running the shipped script against stub
downloaders in a rewritten sandbox:

  * every attempted downloader is named in the FAILED state message;
  * each entry keeps that downloader's own stderr verbatim and adds its real
    exit status, so "Operation not permitted" is traceable to uclient-fetch;
  * the update reports failure and the previous domain/group databases survive;
  * when the first downloader fails and the second one succeeds, the failure
    text of the first is discarded and the update publishes normally (no
    downloader rc leaks into the OK state).

Red half: run it against a copy without the per-downloader aggregation and the
message names only the last attempted downloader:

    TRAFFICCHART_DOMAINS_UPDATE_UNDER_TEST=/tmp/copy/domains-update \\
        python3 scripts/tests/test_trafficchart_dns_error.py

Run from the repository root:

    python3 scripts/tests/test_trafficchart_dns_error.py
"""

import hashlib
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(
    os.environ.get(
        "TRAFFICCHART_DOMAINS_UPDATE_UNDER_TEST",
        REPO_ROOT / "package/luci-app-traffic-chart/root/usr/libexec/trafficchart-domains-update",
    )
)

UCLIENT_STDERR = "Failed to send request: Operation not permitted"
WGET_STDERR = "wget: server returned error: HTTP/1.1 403 Forbidden"
CURL_STDERR = "curl: (28) Connection timed out after 15000 milliseconds"

# Two bootstrap rows, as shipped before any successful v2fly download.
OLD_DOMAINS = "=example.com\tExample\t\n~keyword\tExample\t\n"
OLD_GROUPS = "category-ads-all\ncategory-porn\n"

# Enough distinct rules to clear the parser's 100-rule refusal threshold.
RULE_COUNT = 120


def _rewrite_script(source: str, root: Path) -> str:
    """Redirect the script's absolute /etc, /var/run and /tmp paths into root."""
    text = source.replace(
        "/tmp/trafficchart-domains.XXXXXX",
        f"{root}/tmp/trafficchart-domains.XXXXXX",
    )
    text = text.replace("/var/run", f"{root}/var/run")
    text = text.replace("/etc", f"{root}/etc")
    return text


def _synthetic_release(count: int = RULE_COUNT) -> tuple[str, str]:
    """A minimal v2fly-shaped rule list plus its release checksum file."""
    lines = ["  - name: category-ads-all", "  - domain:ads.example"]
    for index in range(count):
        lines.append(f"  - name: app{index:03d}")
        lines.append(f"  - domain:d{index:03d}.example")
    payload = "\n".join(lines) + "\n"
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    return payload, f"{digest}  dlc.dat_plain.yml\n"


class _SandboxCase(unittest.TestCase):
    """Run the shipped script with /etc, /var/run and /tmp redirected into tmpdir."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="trafficchart-dns-error-")
        self.addCleanup(shutil.rmtree, self.tmpdir)
        root = Path(self.tmpdir)
        self.root = root
        for directory in (root / "etc", root / "var/run", root / "tmp", root / "bin"):
            directory.mkdir(parents=True, exist_ok=True)

        self.logger_log = root / "logger.log"
        self._stub(root / "bin/uclient-fetch", UCLIENT_STDERR, 1)
        self._stub(root / "bin/wget", WGET_STDERR, 1)
        self._stub(root / "bin/curl", CURL_STDERR, 28)
        logger = root / "bin/logger"
        logger.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" >> "$LOGGER_LOG"\n',
            encoding="utf-8",
        )
        logger.chmod(0o755)

        self.domains = root / "etc/trafficchart-domains"
        self.groups = root / "etc/trafficchart-domain-groups"
        self.state = root / "etc/trafficchart-domains.state"
        self.domains.write_text(OLD_DOMAINS, encoding="utf-8")
        self.groups.write_text(OLD_GROUPS, encoding="utf-8")

        self.script = root / "trafficchart-domains-update"
        self.script.write_text(
            _rewrite_script(SCRIPT.read_text(encoding="utf-8"), root),
            encoding="utf-8",
        )

        self.env = os.environ.copy()
        self.env["PATH"] = f"{root / 'bin'}:{self.env['PATH']}"
        self.env["LOGGER_LOG"] = str(self.logger_log)

    @staticmethod
    def _stub(path: Path, stderr: str, rc: int) -> None:
        path.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' {shlex.quote(stderr)} >&2\n"
            f"exit {rc}\n",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def _succeeding_wget(self, payload: str, checksum: str) -> None:
        """Replace the wget stub with one that writes the release files."""
        payload_path = self.root / "payload.yml"
        checksum_path = self.root / "payload.sha256sum"
        payload_path.write_text(payload, encoding="utf-8")
        checksum_path.write_text(checksum, encoding="utf-8")
        wget = self.root / "bin/wget"
        wget.write_text(
            "#!/bin/sh\n"
            "dst= prev=\n"
            'for arg in "$@"; do\n'
            '  [ "$prev" = "-O" ] && dst=$arg\n'
            "  prev=$arg\n"
            "done\n"
            'case "$dst" in\n'
            f'  *.sha256sum) cp {shlex.quote(str(checksum_path))} "$dst" ;;\n'
            f'  *) cp {shlex.quote(str(payload_path))} "$dst" ;;\n'
            "esac\n",
            encoding="utf-8",
        )
        wget.chmod(0o755)

    def _run(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["sh", str(self.script)],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def _state_fields(self) -> dict:
        return dict(
            line.split("=", 1)
            for line in self.state.read_text(encoding="utf-8").splitlines()
            if "=" in line
        )


class DnsErrorReporting(_SandboxCase):
    def test_state_names_every_downloader_and_keeps_previous_database(self):
        result = self._run()
        self.assertEqual(
            result.returncode, 1, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )

        fields = self._state_fields()
        self.assertEqual(fields.get("status"), "FAILED")
        message = fields.get("message", "")
        self.assertNotIn("\n", message, "state message must stay one line")

        for tool, rc in (("uclient-fetch", 1), ("wget", 1), ("curl", 28)):
            self.assertIn(
                f"{tool} (rc={rc}):",
                message,
                f"state message lost {tool}'s failure reason: {message}",
            )
        self.assertIn(UCLIENT_STDERR, message)
        self.assertIn(WGET_STDERR, message)
        self.assertIn(CURL_STDERR, message)

        self.assertEqual(fields.get("last_success"), "0")
        self.assertEqual(fields.get("rules"), "2")
        self.assertEqual(self.domains.read_text(encoding="utf-8"), OLD_DOMAINS)
        self.assertEqual(self.groups.read_text(encoding="utf-8"), OLD_GROUPS)

        log = self.logger_log.read_text(encoding="utf-8")
        self.assertIn("v2fly domain list update failed", log)
        self.assertIn(UCLIENT_STDERR, log)


class SecondDownloaderSuccess(_SandboxCase):
    def test_first_failure_is_discarded_when_the_second_downloader_succeeds(self):
        payload, checksum = _synthetic_release()
        self._succeeding_wget(payload, checksum)

        result = self._run()
        self.assertEqual(
            result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )

        fields = self._state_fields()
        message = fields.get("message", "")
        self.assertEqual(fields.get("status"), "OK", message)
        self.assertEqual(message, "update successful")
        self.assertNotIn("rc=", message, f"a downloader failure leaked into OK: {message}")
        self.assertEqual(fields.get("rules"), str(RULE_COUNT + 1))
        self.assertEqual(fields.get("previous_rules"), "2")
        self.assertEqual(fields.get("changed"), "yes")
        self.assertNotEqual(fields.get("last_success"), "0")

        rows = self.domains.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(rows), RULE_COUNT + 1)
        self.assertIn("d000.example\tApp000\t", rows)
        self.assertIn("ads.example\t\tcategory-ads-all", rows)
        self.assertEqual(
            self.groups.read_text(encoding="utf-8"), "category-ads-all\n"
        )

        log = self.logger_log.read_text(encoding="utf-8")
        self.assertNotIn("failed", log)
        self.assertIn(f"updated: {RULE_COUNT + 1} rules", log)
        self.assertNotIn(UCLIENT_STDERR, log)


if __name__ == "__main__":
    unittest.main()
