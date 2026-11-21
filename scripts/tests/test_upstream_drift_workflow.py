#!/usr/bin/env python3
"""Offline checks for .github/workflows/upstream-drift.yml.

Issue #189 took the decision (keep the deviation, never rebase) and PR #329
turned it into an exit code: 0 ok / 1 review / 2 must-act / 3 unknown.  This
workflow is the scheduler for that code, so the tests assert the four things a
scheduler can silently get wrong:

  * the trigger: first Monday of a month, and the run itself must stand down
    outside January/April/July/October (GitHub cron has no quarter);
  * the measurement: the job must run `scripts/track-upstream.sh --fetch
    --verdict`, not the old drift report whose exit 1 means "behind at all",
    which is true every week and therefore not a decision;
  * the signal: the exit code and the first 30 `--list-hot` lines must reach
    ``$GITHUB_STEP_SUMMARY``, and code 2 must fail the job -- a green run for
    must-act is exactly as quiet as a green run for nothing-to-do;
  * the runner: ubuntu-latest.  A self-hosted label would sit queued forever
    (this repository has no runners), which is indistinguishable from "no
    drift" to anyone reading the Actions tab.

Pure stdlib: the file is parsed with a small block-YAML reader (mappings,
sequences, block scalars, quoted scalars) because the rest of the tree
deliberately avoids PyYAML, and a test that needs a package the build hosts do
not have is not a gate.

The red proofs mutate a copy: deleting `--verdict` or deleting the quarter-gate
step must make the matching check FAIL, so a passing suite proves the check
reads the file rather than a constant.

Run from the repository root:

    python3 -m unittest scripts.tests.test_upstream_drift_workflow
"""

import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/upstream-drift.yml"

QUARTER_MONTHS = "01|04|07|10"


class YamlError(ValueError):
    pass


def _indent(line):
    lead = line[: len(line) - len(line.lstrip())]
    if "\t" in lead:
        raise YamlError("tab indentation: %r" % line)
    return len(lead)


def _strip_comment(value):
    out = []
    quote = None
    for ch in value:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            out.append(ch)
        elif ch == "#" and (not out or out[-1] == " "):
            break
        else:
            out.append(ch)
    return "".join(out).rstrip()


def _scalar(raw):
    raw = _strip_comment(raw).strip()
    if not raw:
        return None
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
        return raw[1:-1]
    if raw in ("true", "false"):
        return raw == "true"
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    return raw


def _tokenize(text):
    """(indent, text, block-body) for every non-blank, non-comment line."""
    lines = text.splitlines()
    toks = []
    i = 0
    while i < len(lines):
        raw = lines[i]
        stripped = raw.strip()
        indent = _indent(raw)
        i += 1
        if not stripped or stripped.startswith("#"):
            continue
        body = None
        if re.match(r"^[^:#]+:\s+[|>][-+]?$", stripped):
            body_lines = []
            while i < len(lines):
                follow = lines[i]
                if follow.strip() and _indent(follow) <= indent:
                    break
                body_lines.append(follow)
                i += 1
            widths = [len(b) - len(b.lstrip(" ")) for b in body_lines if b.strip()]
            cut = min(widths) if widths else 0
            body = "\n".join(b[cut:] for b in body_lines)
        m = re.match(r"^-\s+(.+)$", stripped)
        if m and re.match(r"^[^:#]+:(\s|$)", m.group(1)):
            # "- name: x" -> a sequence item holding a mapping.
            toks.append([indent, "-", None])
            toks.append([indent + 2, m.group(1), body])
        else:
            toks.append([indent, stripped, body])
    return toks


def _parse(text):
    toks = _tokenize(text)
    if not toks:
        raise YamlError("empty document")

    def block(i, indent):
        if toks[i][1] == "-" or toks[i][1].startswith("- "):
            return sequence(i, indent)
        return mapping(i, indent)

    def mapping(i, indent):
        out = {}
        while i < len(toks) and toks[i][0] == indent and not toks[i][1].startswith("-"):
            text = toks[i][1]
            m = re.match(r"^([^:#]+?):(\s*)(.*)$", text)
            if not m:
                raise YamlError("line %d: expected 'key: value', got %r" % (i + 1, text))
            key = m.group(1).strip()
            raw = m.group(3)
            body = toks[i][2]
            if key in out:
                raise YamlError("line %d: duplicate key %r" % (i + 1, key))
            i += 1
            if body is not None:
                out[key] = body
            elif raw:
                out[key] = _scalar(raw)
            elif i < len(toks) and toks[i][0] > indent:
                out[key], i = block(i, toks[i][0])
            else:
                out[key] = None
        if i < len(toks) and toks[i][0] > indent:
            raise YamlError("line %d: unexpected indentation" % (i + 1))
        return out, i

    def sequence(i, indent):
        out = []
        while i < len(toks) and toks[i][0] == indent and toks[i][1].startswith("-"):
            text = toks[i][1]
            rest = text[1:].strip()
            i += 1
            if rest:
                out.append(_scalar(rest))
            elif i < len(toks) and toks[i][0] > indent:
                value, i = block(i, toks[i][0])
                out.append(value)
            else:
                out.append(None)
        if i < len(toks) and toks[i][0] > indent:
            raise YamlError("line %d: bad indentation under a sequence" % (i + 1))
        return out, i

    value, idx = block(0, toks[0][0])
    if idx != len(toks):
        raise YamlError("line %d: trailing content %r" % (idx + 1, toks[idx][1]))
    return value


def _load(text):
    try:
        return _parse(text)
    except YamlError as exc:
        raise AssertionError("not valid YAML: %s" % exc)


def _steps(doc):
    jobs = doc.get("jobs") or {}
    out = []
    for job in jobs.values():
        out.extend(job.get("steps") or [])
    return out


def _run_text(doc):
    return "\n".join(step.get("run") or "" for step in _steps(doc))


def problems_yaml(text):
    problems = []
    if "\t" in text:
        problems.append("workflow contains a tab (YAML forbids tab indentation)")
    try:
        doc = _parse(text)
    except YamlError as exc:
        return problems + ["not valid YAML: %s" % exc]
    if not isinstance(doc, dict):
        return problems + ["top level is not a mapping"]
    for key in ("name", "on", "jobs"):
        if key not in doc:
            problems.append("missing top-level key %r" % key)
    return problems


def problems_schedule(text):
    doc = _load(text)
    problems = []
    schedule = (doc.get("on") or {}).get("schedule")
    if not schedule:
        return ["no on.schedule entry"]
    crons = [entry.get("cron") for entry in schedule if isinstance(entry, dict)]
    if not crons or not crons[0]:
        return ["no cron expression in on.schedule"]
    fields = crons[0].split()
    if len(fields) != 5:
        problems.append("cron %r is not five fields" % crons[0])
    else:
        _, _, day_of_month, _, day_of_week = fields
        if day_of_month != "1-7":
            problems.append("cron day-of-month is %r, not 1-7 (first Monday)" % day_of_month)
        if day_of_week != "1":
            problems.append("cron day-of-week is %r, not 1 (Monday)" % day_of_week)
    return problems


def problems_dispatch(text):
    doc = _load(text)
    dispatch = (doc.get("on") or {}).get("workflow_dispatch")
    if dispatch is None:
        return ["no on.workflow_dispatch (manual run is the only way to exercise this before the first quarter)"]
    mode = ((dispatch.get("inputs") or {}).get("mode")) or {}
    problems = []
    if mode.get("default") != "verdict":
        problems.append("workflow_dispatch input mode default is %r, not 'verdict'" % mode.get("default"))
    if mode.get("options") != ["verdict", "check"]:
        problems.append("mode options are %r, not [verdict, check]" % (mode.get("options"),))
    return problems


def problems_verdict(text):
    doc = _load(text)
    run = _run_text(doc)
    problems = []
    if "--verdict" not in run:
        problems.append("no step runs track-upstream.sh --verdict; the drift report cannot triage")
    if "--fetch" not in run:
        problems.append("no step passes --fetch; the verdict would read stale refs")
    for line in run.splitlines():
        if "track-upstream.sh" in line and "--verdict" in line:
            if "--fetch" not in line:
                problems.append("verdict line does not fetch first: %r" % line.strip())
    return problems


def problems_summary(text):
    doc = _load(text)
    run = _run_text(doc)
    problems = []
    if "$GITHUB_STEP_SUMMARY" not in run:
        problems.append("the verdict is not written to $GITHUB_STEP_SUMMARY")
    if "--list-hot" not in run:
        problems.append("no step lists hot commits (--list-hot); must-act arrives with no worklist")
    if not re.search(r"head\s+-30\s+hot\.txt", run):
        problems.append("the hot list is not truncated to its first 30 lines")
    return problems


def problems_quarter_gate(text):
    doc = _load(text)
    problems = []
    steps = _steps(doc)
    gate = [s for s in steps if s.get("id") == "quarter"]
    if not gate:
        return ["no step with id 'quarter'; a monthly cron would run in every month"]
    run = gate[0].get("run") or ""
    if QUARTER_MONTHS not in run:
        problems.append("the quarter gate never tests months %s" % QUARTER_MONTHS)
    if "不是季度首月，跳过" not in run:
        problems.append("the quarter gate does not print the reason it skipped")
    if "exit 0" not in run:
        problems.append("the quarter gate does not exit 0 outside a quarter month")
    if "GITHUB_OUTPUT" not in run:
        problems.append("the quarter gate does not tell later steps whether it ran")
    return problems


def problems_runner(text):
    doc = _load(text)
    problems = []
    if "self-hosted" in text:
        problems.append("workflow asks for a self-hosted runner (this repository has none)")
    for name, job in ((doc.get("jobs") or {})).items():
        if job.get("runs-on") != "ubuntu-latest":
            problems.append("job %r runs on %r, not ubuntu-latest" % (name, job.get("runs-on")))
    return problems


def problems_must_act(text):
    doc = _load(text)
    run = _run_text(doc)
    problems = []
    if "::error::" not in run:
        problems.append("no ::error:: annotation for a failed verdict")
    if not re.search(r'if \[[^\]]*"\$code"\s*-eq\s*2[^\]]*\]', run):
        problems.append("no branch on exit code 2")
    match = re.search(r'if \[[^\]]*"\$code"\s*-eq\s*2[^\]]*\][\s\S]*?exit 1', run)
    if not match:
        problems.append("exit code 2 does not fail the job (no 'exit 1' in that branch)")
    if "must-act" not in run:
        problems.append("the failure message does not name must-act")
    return problems


class UpstreamDriftWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_file_is_valid_yaml(self):
        self.assertEqual(problems_yaml(self.text), [])

    def test_schedule_is_the_first_monday_of_a_month(self):
        self.assertEqual(problems_schedule(self.text), [])

    def test_manual_dispatch_exposes_check_and_verdict(self):
        self.assertEqual(problems_dispatch(self.text), [])

    def test_verdict_is_measured_with_fetch(self):
        self.assertEqual(problems_verdict(self.text), [])

    def test_exit_code_and_hot_list_reach_the_summary(self):
        self.assertEqual(problems_summary(self.text), [])

    def test_non_quarter_months_skip_with_a_reason(self):
        self.assertEqual(problems_quarter_gate(self.text), [])

    def test_runs_on_ubuntu_latest_and_never_self_hosted(self):
        self.assertEqual(problems_runner(self.text), [])

    def test_must_act_fails_the_job(self):
        self.assertEqual(problems_must_act(self.text), [])


class RedProofTest(unittest.TestCase):
    """The checks must fail on a mutated copy, or they assert nothing."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_red_proof_dropping_verdict(self):
        problems = problems_verdict(self.text.replace("--verdict", ""))
        self.assertTrue(problems, "deleting --verdict did not fail the check")
        self.assertRegex(problems[0], r"--verdict")

    def test_red_proof_dropping_quarter_gate(self):
        start = self.text.index("      - name: Run only in the first month of a quarter")
        end = self.text.index("      - name: Fetch upstream and read the verdict")
        problems = problems_quarter_gate(self.text[:start] + self.text[end:])
        self.assertTrue(problems, "deleting the quarter gate did not fail the check")
        self.assertIn("quarter", problems[0])


if __name__ == "__main__":
    unittest.main()
