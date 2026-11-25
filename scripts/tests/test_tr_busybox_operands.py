#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guard the tr(1) operands and options of scripts that run on the XR1710G.

BusyBox v1.38.0 on the router (r38047, /usr/bin/tr) does not implement POSIX
character classes, GNU long options (--delete, --complement), or -C.  Measured
on the device:

    $ printf 'cn\n' | tr '[:lower:]' '[:upper:]'   -> cn
    $ printf 'cn\n' | tr 'a-z' 'A-Z'               -> CN
    $ printf 'a b\tc\n' | tr -d '[:space:]'        -> ' b\t'   (a and c eaten)
    $ printf 'a b\tc\n' | tr -d ' \t\n'            -> abc

So a device-side script may only use BusyBox-supported short flags (-c, -d, -s)
and literal ranges/escapes as operands.  This test parses every tr invocation
in the device-side scripts (including remote shell strings, command
substitutions, `if`/`!`/`then`/`do`/`xargs` prefixes, and redirections before
operands, while ignoring quoted prose such as `echo "tr failed"`), checks
options and operands statically, and replays every invocation through a BusyBox
stand-in comparing byte for byte with host tr.

REPO_ROOT_UNDER_TEST overrides the scanned repository root for red-green runs.

Run from the repository root:

    python3 scripts/tests/test_tr_busybox_operands.py
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(
    os.environ.get("REPO_ROOT_UNDER_TEST") or Path(__file__).resolve().parents[2]
).resolve()

DEVICE_FILES = (
    "scripts/wifi-reg-report.sh",
    "scripts/pcie-single-cut.sh",
    "scripts/check-npu-firmware.sh",
    "scripts/f2-wifi-npu.sh",
    "scripts/bench-10g-unidirectional.sh",
    "scripts/pppoe-4path.sh",
    "package/luci-app-traffic-chart/root/usr/libexec/trafficchart-persist-exec",
    "package/luci-app-traffic-chart/root/usr/libexec/trafficchart-domains-update",
    "package/luci-app-traffic-chart/root/usr/libexec/trafficchart-v6prefixes",
)
DEVICE_GLOBS = (
    ("target/linux/airoha/an7581/base-files", "**/*"),
    ("scripts/wireless", "**/*.sh"),
)

# BusyBox v1.38.0 coreutils/tr.c only accepts -c, -d, -s (and bare --).
BUSYBOX_TR_FLAGS = frozenset("cds")

CMD_PREFIXES = frozenset((
    "if", "then", "elif", "else", "do", "!", "time", "exec", "command",
    "nohup", "setsid",
))
XARGS_VALUE_FLAGS = frozenset(("-I", "-L", "-n", "-P", "-s", "-d", "-E", "-a"))
SHELL_WRAPPERS = frozenset((
    "sh", "ash", "bash", "dash", "eval", "ssh", "rsh", "ssh_run", "ssh_dev",
    "dev_ssh", "remote_sh", "run_remote",
))
ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# BusyBox v1.38.0 stand-in:
# - Rejects GNU long options (--delete, --complement, ...) and any short flag
#   outside {-c, -d, -s} (including -C).
# - Parses combined short flag clusters (e.g. -sd, -cd, -dc) character by char.
# - Leaves POSIX [:class:] unexpanded, copying input through for substitution
#   or deleting the literal operand bytes when -d or -c is set.
TR_STUB = '''#!/usr/bin/env python3
import os, sys

args = sys.argv[1:]
opt_chars = set()
operands = []
end_opts = False
for a in args:
    if not end_opts and a == "--":
        end_opts = True
        continue
    if not end_opts and a.startswith("--"):
        sys.stderr.write("bb-tr: unsupported long option: %s\\n" % a)
        sys.exit(1)
    if not end_opts and a.startswith("-") and len(a) > 1:
        for ch in a[1:]:
            if ch not in "cds":
                sys.stderr.write("bb-tr: unsupported option -%s\\n" % ch)
                sys.exit(1)
            opt_chars.add(ch)
    else:
        operands.append(a)


def unescape(text):
    out = []
    i = 0
    while i < len(text):
        if text[i] == "\\\\" and i + 1 < len(text):
            out.append({"n": "\\n", "t": "\\t", "r": "\\r", "\\\\": "\\\\"}.get(
                text[i + 1], text[i + 1]))
            i += 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


if any("[:" in o for o in operands):
    data = sys.stdin.buffer.read()
    if "d" in opt_chars or "c" in opt_chars:
        unwanted = set(unescape("".join(operands)).encode())
        sys.stdout.buffer.write(bytes(b for b in data if b not in unwanted))
    else:
        sys.stdout.buffer.write(data)
    sys.exit(0)

os.execv(os.environ["REAL_TR"], [os.environ["REAL_TR"]] + args)
'''


def _is_shell_wrapper(cmd: str) -> bool:
    base = cmd.rsplit("/", 1)[-1]
    return (
        base in SHELL_WRAPPERS
        or base.startswith("ssh_")
        or base.endswith(("_ssh", "_rsh"))
    )


def _unescape_dquote(text: str) -> str:
    """Undo one layer of shell double-quote escaping for inner remote code."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] == "\\" and i + 1 < n and text[i + 1] in '"$\\`':
            out.append(text[i + 1])
            i += 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def _scan_subshell(text: str, start: int, lineno: int, nested: list) -> tuple[int, int]:
    """Scan a `$(...)` starting just after `$(`; append extracted calls to nested."""
    n = len(text)
    i = start
    depth = 1
    buf = []
    start_line = lineno
    while i < n and depth > 0:
        ch = text[i]
        if ch == "\n":
            lineno += 1
            buf.append(ch)
            i += 1
        elif ch == "\\" and i + 1 < n:
            if text[i + 1] == "\n":
                lineno += 1
            buf.append(text[i:i + 2])
            i += 2
        elif ch == "'":
            end = text.find("'", i + 1)
            if end < 0:
                end = n - 1
            seg = text[i:end + 1]
            lineno += seg.count("\n")
            buf.append(seg)
            i = end + 1
        elif ch == '"':
            buf.append('"')
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    if text[i + 1] == "\n":
                        lineno += 1
                    buf.append(text[i:i + 2])
                    i += 2
                elif text[i:i + 2] == "$(":
                    buf.append("$(")
                    i, lineno = _scan_subshell_copy(text, i + 2, lineno, buf)
                else:
                    if text[i] == "\n":
                        lineno += 1
                    buf.append(text[i])
                    i += 1
            if i < n:
                buf.append('"')
                i += 1
        elif ch == "(":
            depth += 1
            buf.append(ch)
            i += 1
        elif ch == ")":
            depth -= 1
            if depth > 0:
                buf.append(ch)
            i += 1
        else:
            buf.append(ch)
            i += 1
    nested.extend(extract_tr_calls("".join(buf), start_line))
    return i, lineno


def _scan_subshell_copy(text: str, start: int, lineno: int, buf: list) -> tuple[int, int]:
    """Copy a nested `$(...)` verbatim into buf while maintaining balance."""
    n = len(text)
    i = start
    depth = 1
    while i < n and depth > 0:
        ch = text[i]
        if ch == "\n":
            lineno += 1
            buf.append(ch)
            i += 1
        elif ch == "\\" and i + 1 < n:
            if text[i + 1] == "\n":
                lineno += 1
            buf.append(text[i:i + 2])
            i += 2
        elif ch == "'":
            end = text.find("'", i + 1)
            if end < 0:
                end = n - 1
            seg = text[i:end + 1]
            lineno += seg.count("\n")
            buf.append(seg)
            i = end + 1
        elif ch == "(":
            depth += 1
            buf.append(ch)
            i += 1
        elif ch == ")":
            depth -= 1
            buf.append(ch)
            i += 1
        else:
            buf.append(ch)
            i += 1
    return i, lineno


def extract_tr_calls(text: str, base_line: int = 1) -> list[tuple[int, list[str]]]:
    """Extract `(lineno, argv_after_tr)` for every shell-executed `tr` call.

    Shell-aware tokenizer: tracks multiline single/double quotes, skips heredoc
    bodies and comments, recurses into `$(...)` / backticks (even inside double
    quotes) and into quoted command arguments of shell/ssh wrappers, handles
    redirections in any position (including before operands), and ignores
    quoted prose like `echo "tr failed"`.
    """
    calls: list[tuple[int, list[str]]] = []
    tokens = []  # list of (kind, value, lineno, raw_quoted_kind, raw_quoted_text)
    pending_heredocs: list[str] = []

    i = 0
    n = len(text)
    lineno = base_line

    def skip_heredocs(pos: int, cur_line: int) -> tuple[int, int]:
        while pending_heredocs and pos < n:
            delim = pending_heredocs.pop(0)
            while pos < n:
                nl = text.find("\n", pos)
                if nl < 0:
                    line_s = text[pos:]
                    pos = n
                else:
                    line_s = text[pos:nl]
                    pos = nl + 1
                    cur_line += 1
                if line_s.lstrip("\t") == delim or line_s == delim:
                    break
        return pos, cur_line

    while i < n:
        ch = text[i]
        if ch in " \t\r":
            i += 1
            continue
        if ch == "\\" and i + 1 < n and text[i + 1] == "\n":
            i += 2
            lineno += 1
            continue
        if ch == "\n":
            tokens.append(("SEP", "\n", lineno, "", ""))
            i += 1
            lineno += 1
            if pending_heredocs:
                i, lineno = skip_heredocs(i, lineno)
            continue
        if ch == "#":
            nl = text.find("\n", i)
            i = n if nl < 0 else nl
            continue
        if text[i:i + 2] in ("&&", "||", ";;"):
            tokens.append(("SEP", text[i:i + 2], lineno, "", ""))
            i += 2
            continue
        if ch in "|;&()":
            tokens.append(("SEP", ch, lineno, "", ""))
            i += 1
            continue

        # Redirection operator (with optional leading fd digits).
        fd_j = i
        while fd_j < n and text[fd_j].isdigit():
            fd_j += 1
        if fd_j < n and text[fd_j] in "<>":
            op_start = fd_j
            if text[op_start:op_start + 3] == "<<<":
                op_end = op_start + 3
            elif text[op_start:op_start + 2] in ("<<", ">>", "<&", ">&", "<>", ">|"):
                op_end = op_start + 2
                if text[op_start:op_start + 3] == "<<-":
                    op_end = op_start + 3
            else:
                op_end = op_start + 1
            op = text[op_start:op_end]
            i = op_end
            if op in ("<<", "<<-"):
                while i < n and text[i] in " \t":
                    i += 1
                dbuf = []
                while i < n and text[i] not in " \t\r\n|;&()<>#":
                    if text[i] in ("'", '"'):
                        q = text[i]
                        end = text.find(q, i + 1)
                        if end < 0:
                            end = n - 1
                        dbuf.append(text[i + 1:end])
                        i = end + 1
                    elif text[i] == "\\" and i + 1 < n:
                        dbuf.append(text[i + 1])
                        i += 2
                    else:
                        dbuf.append(text[i])
                        i += 1
                if dbuf:
                    pending_heredocs.append("".join(dbuf))
                tokens.append(("REDIR_SELF", op, lineno, "", ""))
            else:
                # Attached target (e.g. <"$f" or 2>/dev/null) vs separate target.
                attached = i < n and text[i] not in " \t\r\n|;&()<>#"
                if attached:
                    # Consume the attached target word cleanly.
                    while i < n and text[i] not in " \t\r\n|;&()<>#":
                        if text[i] == "'":
                            end = text.find("'", i + 1)
                            end = n - 1 if end < 0 else end
                            lineno += text[i:end + 1].count("\n")
                            i = end + 1
                        elif text[i] == '"':
                            i += 1
                            while i < n and text[i] != '"':
                                if text[i] == "\\" and i + 1 < n:
                                    if text[i + 1] == "\n":
                                        lineno += 1
                                    i += 2
                                elif text[i:i + 2] == "$(":
                                    i, lineno = _scan_subshell(text, i + 2, lineno, calls)
                                else:
                                    if text[i] == "\n":
                                        lineno += 1
                                    i += 1
                            if i < n:
                                i += 1
                        elif text[i] == "\\" and i + 1 < n:
                            if text[i + 1] == "\n":
                                lineno += 1
                            i += 2
                        else:
                            i += 1
                    tokens.append(("REDIR_SELF", op, lineno, "", ""))
                else:
                    tokens.append(("REDIR_NEXT", op, lineno, "", ""))
            continue

        # Regular shell word.
        tok_line = lineno
        buf = []
        raw_qkind = ""
        raw_qparts = []
        all_quoted = True
        while i < n and text[i] not in " \t\r\n|;&()<>":
            c = text[i]
            if c == "'":
                end = text.find("'", i + 1)
                if end < 0:
                    seg = text[i + 1:]
                    i = n
                else:
                    seg = text[i + 1:end]
                    i = end + 1
                lineno += seg.count("\n")
                buf.append(seg)
                raw_qkind = raw_qkind or "'"
                raw_qparts.append(seg)
            elif c == '"':
                i += 1
                qbuf = []
                while i < n and text[i] != '"':
                    if text[i] == "\\" and i + 1 < n:
                        nxt = text[i + 1]
                        if nxt == "\n":
                            lineno += 1
                            i += 2
                            continue
                        qbuf.append(text[i:i + 2])
                        buf.append(nxt if nxt in '"$\\`' else text[i:i + 2])
                        i += 2
                    elif text[i:i + 2] == "$(":
                        i, lineno = _scan_subshell(text, i + 2, lineno, calls)
                        qbuf.append("$(...)")
                        buf.append("$(...)")
                    elif text[i] == "`":
                        end = text.find("`", i + 1)
                        if end < 0:
                            end = n - 1
                        inner = text[i + 1:end]
                        calls.extend(extract_tr_calls(inner, lineno))
                        lineno += inner.count("\n")
                        qbuf.append("`...`")
                        buf.append("`...`")
                        i = end + 1
                    else:
                        if text[i] == "\n":
                            lineno += 1
                        qbuf.append(text[i])
                        buf.append(text[i])
                        i += 1
                if i < n:
                    i += 1
                raw_qkind = raw_qkind or '"'
                raw_qparts.append("".join(qbuf))
            elif text[i:i + 2] == "$(":
                all_quoted = False
                i, lineno = _scan_subshell(text, i + 2, lineno, calls)
                buf.append("$(...)")
            elif c == "`":
                all_quoted = False
                end = text.find("`", i + 1)
                if end < 0:
                    end = n - 1
                inner = text[i + 1:end]
                calls.extend(extract_tr_calls(inner, lineno))
                lineno += inner.count("\n")
                buf.append("`...`")
                i = end + 1
            elif c == "\\" and i + 1 < n:
                all_quoted = False
                if text[i + 1] == "\n":
                    lineno += 1
                    i += 2
                else:
                    buf.append(text[i + 1])
                    i += 2
            else:
                all_quoted = False
                buf.append(c)
                i += 1
        word = "".join(buf)
        tokens.append((
            "WORD",
            word,
            tok_line,
            raw_qkind if (all_quoted and raw_qkind) else "",
            "".join(raw_qparts) if (all_quoted and raw_qkind) else "",
        ))

    # Split token stream into simple commands separated by SEP tokens.
    segments = []
    cur = []
    for tok in tokens:
        if tok[0] == "SEP":
            if cur:
                segments.append(cur)
                cur = []
        else:
            cur.append(tok)
    if cur:
        segments.append(cur)

    for seg in segments:
        # Remove redirections and their separate targets while keeping all real words.
        words = []
        skip_next = False
        for kind, val, tline, qkind, qraw in seg:
            if skip_next:
                skip_next = False
                continue
            if kind == "REDIR_SELF":
                continue
            if kind == "REDIR_NEXT":
                skip_next = True
                continue
            words.append((val, tline, qkind, qraw))

        idx = 0
        while idx < len(words):
            w, _, qkind, _ = words[idx]
            if not qkind and (w in CMD_PREFIXES or ENV_ASSIGN_RE.match(w)):
                idx += 1
                continue
            if not qkind and w == "xargs":
                idx += 1
                while idx < len(words) and words[idx][0].startswith("-"):
                    flag = words[idx][0]
                    idx += 1
                    if flag in XARGS_VALUE_FLAGS and idx < len(words):
                        idx += 1
                continue
            break

        if idx >= len(words):
            continue

        cmd_word, cmd_line, cmd_qkind, _ = words[idx]
        if not cmd_qkind and cmd_word == "tr":
            argv = [w for w, _, _, _ in words[idx + 1:]]
            if argv:
                calls.append((cmd_line, argv))
        elif not cmd_qkind and _is_shell_wrapper(cmd_word):
            for val, wline, qkind, qraw in words[idx + 1:]:
                if qkind == "'":
                    calls.extend(extract_tr_calls(qraw, wline))
                elif qkind == '"':
                    calls.extend(extract_tr_calls(_unescape_dquote(qraw), wline))

    calls.sort(key=lambda item: item[0])
    return calls


def real_tr():
    found = shutil.which("tr")
    if not found:
        raise unittest.SkipTest("no tr(1) on this host")
    return found


def scan_files(repo_root: Path | None = None):
    """Return sorted deduplicated repo-relative paths for all scanned scripts."""
    root_dir = REPO_ROOT if repo_root is None else repo_root
    seen = set()
    ordered = []
    for name in DEVICE_FILES:
        if name not in seen:
            seen.add(name)
            ordered.append(name)
    for base, pattern in DEVICE_GLOBS:
        root = root_dir / base
        if not root.is_dir():
            continue
        for path in sorted(root.glob(pattern)):
            if not path.is_file():
                continue
            rel = path.relative_to(root_dir).as_posix()
            if rel not in seen:
                seen.add(rel)
                ordered.append(rel)
    return ordered


def tr_calls(repo_root: Path | None = None):
    """Yield (file, line number, argv-after-tr) for every device-side call."""
    root_dir = REPO_ROOT if repo_root is None else repo_root
    for name in scan_files(root_dir):
        path = root_dir / name
        if not path.exists():
            raise AssertionError("missing device script: %s" % name)
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, argv in extract_tr_calls(text):
            yield name, lineno, argv


def invalid_tr_options(argv: list[str]) -> list[str]:
    """Return any BusyBox-unsupported options in a tr argv list."""
    bad = []
    for arg in argv:
        if arg == "--":
            break
        if arg.startswith("--"):
            bad.append(arg)
        elif arg.startswith("-") and len(arg) > 1:
            for ch in arg[1:]:
                if ch not in BUSYBOX_TR_FLAGS:
                    bad.append("-" + ch)
    return bad


class BusyBoxTrOperandTest(unittest.TestCase):
    def setUp(self):
        self.tr = real_tr()
        self.tmp = tempfile.mkdtemp(prefix="bbtr-")
        self.stub = Path(self.tmp) / "bb-tr"
        self.stub.write_text(TR_STUB)
        self.stub.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_operands_are_class_free(self):
        offenders = [
            "%s:%d: tr %s" % (name, lineno, " ".join(argv))
            for name, lineno, argv in tr_calls()
            if any("[:" in arg for arg in argv)
        ]
        self.assertEqual(
            offenders, [],
            "tr operand uses a POSIX class that BusyBox does not expand; "
            "use 'a-z' 'A-Z' or an explicit ' \\t\\n' set instead")

    def test_options_are_busybox_safe(self):
        offenders = [
            "%s:%d: tr %s (bad: %s)" % (name, lineno, " ".join(argv), ", ".join(bad))
            for name, lineno, argv in tr_calls()
            for bad in (invalid_tr_options(argv),)
            if bad
        ]
        self.assertEqual(
            offenders, [],
            "tr uses options BusyBox does not support (only -c, -d, -s are allowed)")

    def test_operands_behave_like_host_tr_under_busybox(self):
        calls = list(tr_calls())
        self.assertTrue(calls, "no tr call found in the device scripts")
        for name, lineno, argv in calls:
            want = self._run([self.tr] + argv)
            got = self._run([sys.executable, str(self.stub)] + argv)
            self.assertEqual(
                got, want, "%s:%d: tr %s is not BusyBox-safe"
                % (name, lineno, " ".join(argv)))

    def test_parser_and_stub_edge_cases(self):
        sample = "\n".join([
            'echo "tr failed"',
            "printf 'tr -d [:space:]'",
            "if tr '\\000' '\\n' < \"$f\" | grep -q x; then tr 'a-z' 'A-Z'; fi",
            "! tr -d '\\r'",
            "for x in a; do tr ',' ' '; done",
            "find . | xargs -0 tr -d '\\n'",
            "tr < \"$f\" -d '[:space:]'",
            'rsh "tr \'[:upper:]\' \'[:lower:]\'" && echo "tr failed" && rsh "tr \'a-z\' \'A-Z\'"',
        ])
        found = extract_tr_calls(sample)
        argvs = [argv for _, argv in found]
        self.assertEqual(
            argvs,
            [
                ["\\000", "\\n"],
                ["a-z", "A-Z"],
                ["-d", "\\r"],
                [",", " "],
                ["-d", "\\n"],
                ["-d", "[:space:]"],
                ["[:upper:]", "[:lower:]"],
                ["a-z", "A-Z"],
            ],
            "parser missed edge cases or matched quoted prose: %r" % (found,),
        )
        # Stub rejects GNU long options and -C.
        for bad_args in (["--delete", "a"], ["--complement", "-d", "a"], ["-C", "-d", "a"]):
            self.assertTrue(invalid_tr_options(bad_args), bad_args)
            proc = subprocess.run(
                [sys.executable, str(self.stub)] + bad_args,
                input=b"abc\n",
                env=dict(os.environ, REAL_TR=self.tr),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            self.assertNotEqual(proc.returncode, 0, bad_args)
        # Stub catches combined flags (-sd, -cd) with a POSIX class.
        for bad_combo in (["-sd", "[:space:]", "a"], ["-cd", "[:digit:]"]):
            want = self._run([self.tr] + bad_combo)
            got = self._run([sys.executable, str(self.stub)] + bad_combo)
            self.assertNotEqual(
                got, want, "TR_STUB missed combined flags %r" % (bad_combo,)
            )
        # Missing DEVICE_FILES entry fails loudly instead of silently skipping.
        empty_root = Path(self.tmp) / "empty-repo"
        empty_root.mkdir()
        with self.assertRaises(AssertionError):
            list(tr_calls(empty_root))

    def _run(self, command):
        # Probe covers what the call sites touch: case, spaces, tabs,
        # newlines, digits and hex letters.  Operands are passed as argv, not
        # re-quoted, so a literal backslash-n reaches tr the way sh passes it.
        env = dict(os.environ, REAL_TR=self.tr)
        proc = subprocess.run(
            command, input=b"a b\tc\nCN cn 1 2\n0x7f\t  10\n",
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(
            proc.returncode, 0,
            "tr invocation %r failed (rc=%d): %s"
            % (command, proc.returncode, proc.stderr.decode(errors="replace")),
        )
        return proc.stdout


if __name__ == "__main__":
    unittest.main()
