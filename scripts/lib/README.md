# scripts/lib

Shared helpers for the XR1710G experiment scripts.

## netwatchdog-guard.sh

`netwatchdog-guard.sh` is a POSIX-sh library that takes the `netwatchdog`
reboot hold around an experiment that can drop the network or reboot the
board, releases it on EXIT/HUP/INT/TERM, and records the hold/resume times.  It
never modifies `netwatchdog` or its configuration.

Sourcing the file does nothing until `nw_guard_init` is called.  The default
mode is dry-run: it never runs `netwatchdog` and never writes a file.  Only
`--apply` takes a hold.

### Integration

```sh
#!/bin/sh
...
. "$(dirname "$0")/../lib/netwatchdog-guard.sh"

apply=0
while [ $# -gt 0 ]; do
	case $1 in
	--apply) apply=1 ;;
	--dry-run) apply=0 ;;
	esac
	shift
done

if [ "$apply" -eq 1 ]; then
	nw_guard_init --apply --result-json "$OUT/netwatchdog.json" --label "$PROG"
else
	nw_guard_init --dry-run
fi
nw_guard_take              # warning only; never aborts
... destructive steps, never reached in dry-run ...
```

`nw_guard_take` is a no-op in dry-run mode and does not even look for
`netwatchdog`, so `--dry-run` cannot change the hold.  The calling script still
owns its destructive steps and must gate them on its own apply flag; the guard
only protects the hold.

If the script already owns an EXIT/HUP/INT/TERM trap, pass `--no-trap` and call
`nw_guard_cleanup` from that trap instead.

### Functions

| Function | Purpose |
|---|---|
| `nw_guard_init ...` | parse mode/options, reset state, install the trap |
| `nw_guard_take` | check the service, take the hold if it is off; warn only |
| `nw_guard_release` | release a hold this guard took; print the manual command on failure |
| `nw_guard_cleanup` | release + write the JSON record; idempotent and trap-safe |
| `nw_guard_state` | print `on`, `off` or `missing`; read-only, safe in a dry run |

The calling shell sees `NW_GUARD_ACTION`, `NW_GUARD_RESULT`, `NW_GUARD_HOLD_AT`
and `NW_GUARD_RESUME_AT` after each call.

### Behavior

- An already-active hold is left active and is never released by this guard.
- A missing `netwatchdog` or a failing `hold on` is a warning only; the
  experiment continues so its result can still be recorded.
- A hold this guard took is released on EXIT, HUP, INT and TERM, including a
  nonzero exit or `set -e` abort.
- A release failure prints the exact manual command to run and records it in
  the JSON.

### Result JSON

`--result-json PATH` writes this record on cleanup when `--apply` was used
(nothing is written in dry-run).  The parent directory must exist.

```json
{
  "service": "netwatchdog",
  "command": "netwatchdog",
  "label": "thermal-soak",
  "mode": "apply",
  "hold_file": "/tmp/netwatchdog.hold",
  "service_present": true,
  "prior_hold": false,
  "hold_at": "2026-11-15T00:20:00Z",
  "hold_epoch": 1763166000,
  "resume_at": "2026-11-15T00:35:00Z",
  "resume_epoch": 1763166900,
  "signal": null,
  "action": "took-and-released",
  "result": "ok",
  "manual_command": null
}
```

`action` is one of `not-taken`, `skipped-dry-run`, `missing`, `unchanged`,
`took`, `took-and-released`, `take-failed`, `took-release-failed`.
`result` is one of `ok`, `dry-run`, `missing-service`, `hold-failed`,
`hold-command-failed`, `release-failed`.

A release failure also prints:

```
netwatchdog-guard: warning: netwatchdog hold off failed; release the hold manually:
  netwatchdog hold off
  test ! -e /tmp/netwatchdog.hold   # verify it is gone
```

### Test

```sh
sh scripts/lib/netwatchdog-guard-test.sh
SH='busybox sh' sh scripts/lib/netwatchdog-guard-test.sh
shellcheck -s sh scripts/lib/netwatchdog-guard.sh scripts/lib/netwatchdog-guard-test.sh
```
