# SPDX-License-Identifier: GPL-2.0-or-later
"""Cleanup helpers for the test suite.

Why this module exists: on 2026-11-21 a test printed a record path, parsed it
back out of the program under test, and cleaned up with

    shutil.rmtree(record_path.parent)

Fed a broken copy of the script - one that printed ``/tmp/result.json``
instead of a per-run directory - ``Path("/tmp/result.json").parents[1]`` is
``Path("/")``, so the cleanup called ``shutil.rmtree("/")`` and, before it was
killed, deleted a 100+ GB build tree outside the repository.  No backup.

The mistake was survivable; the pattern is not.  A path parsed out of the
program under test is input, and a test is allowed to swap that program
(``SIXG_RX_UNDER_TEST`` and friends), so it can never be trusted to name a
directory that is safe to delete.  Every such cleanup goes through
``safe_rmtree``, which only accepts a directory the repository itself
created.
"""

import re
import shutil
import sys
from pathlib import Path

# Directories a run directory may live in.  Only these two, resolved: a
# record under /home, /mnt, or a build tree is never a disposable run
# directory.  Overridable for the guard's own test.
SCRATCH_ROOTS = (Path("/tmp"), Path("/var/tmp"))

# The naming convention of the record directories this repository creates:
# ``<script-base>-no-client.<UTC stamp>.<pid>``, see
# scripts/wireless/lib/no-client.sh (no_client_default_dir).  Default deny:
# a name that does not match is not ours to remove.
RECORD_DIR_NAME = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9._-]*-no-client\.[A-Za-z0-9][A-Za-z0-9._-]*$"
)


def _refuse(path):
    # Never raise from a cleanup: an exception here hides the real failure.
    sys.stderr.write(
        "safe_rmtree: refusing to remove %s "
        "(not a disposable run directory)\n" % path
    )


def safe_rmtree(path):
    """Remove a directory only when it is a disposable run directory.

    Refuses anything that is not a direct child of a known scratch root:
    a test that parses a path out of the script under test must never be
    able to delete an unrelated tree by feeding it a different script.
    """
    try:
        target = Path(path).resolve()
    except (OSError, RuntimeError):
        _refuse(path)
        return False
    roots = tuple(root.resolve() for root in SCRATCH_ROOTS)
    # "/" has one part, "/tmp" and "/home" two; a direct child of a scratch
    # root has three.  The parent check then rejects /home and /mnt/*, and
    # the name check rejects anything that is not a run directory.
    if (
        len(target.parts) < 3
        or target.parent not in roots
        or not RECORD_DIR_NAME.match(target.name)
    ):
        _refuse(path)
        return False
    shutil.rmtree(target)
    return True
