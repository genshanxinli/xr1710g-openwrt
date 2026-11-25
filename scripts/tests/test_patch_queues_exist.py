"""Every patch queue a consumer names must exist on disk (#374).

The 7.3 airoha queue was retired after its 34 lost message headers were
restored into patches-7.4.  A file that still points a reader at
target/linux/airoha/patches-<ver> is either a stale redirect or an
intentional version fixture; the latter must be listed in ALLOWED with the
reason it does not name a live queue.
"""

import os, re
import unittest
from pathlib import Path

REPO = Path(os.environ.get("REPO_ROOT_UNDER_TEST") or Path(__file__).resolve().parents[2]).resolve()
QUEUE = re.compile(r"patches-(\d+\.\d+)")
SCAN = ("scripts", "target/linux/airoha")
SUFFIX = {".sh", ".py", ".md", ".mk", ".yaml", ".patch"}
# #374: airoha keeps 7.4 (default) and 6.18 (KERNEL_PATCHVER).
RETIRED = {"7.3"}

# Literals that are not patch-queue consumers (docstring examples or temp-dir
# fixtures only); each entry needs its reason.
ALLOWED = {
    "scripts/check-release-image-features.py",         # docstring example
    "scripts/tests/check-release-image-features.py",   # version-parser fixtures built in temp dirs
    "scripts/tests/test_claims_verify.py",             # FixtureRoot lives in a temp dir
    "scripts/tests/test_patch_queues_exist.py",        # this file
}


class PatchQueueConsumersTest(unittest.TestCase):
    def test_consumers_point_at_live_queues(self):
        stale = []
        for top in SCAN:
            for path in (REPO / top).rglob("*"):
                if path.suffix not in SUFFIX or not path.is_file():
                    continue
                rel = path.relative_to(REPO).as_posix()
                if rel in ALLOWED:
                    continue
                text = path.read_text(encoding="utf-8", errors="replace")
                for ver in set(QUEUE.findall(text)):
                    queue = REPO / "target/linux/airoha" / f"patches-{ver}"
                    if ver in RETIRED or not queue.is_dir():
                        stale.append(f"{rel}: patches-{ver}")
        self.assertEqual([], stale)

    def test_retired_queue_stays_retired(self):
        self.assertFalse((REPO / "target/linux/airoha/patches-7.3").exists())


if __name__ == "__main__":
    unittest.main()
