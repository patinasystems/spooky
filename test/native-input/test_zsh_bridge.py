#!/usr/bin/env python3
"""PTY integration tests for the opt-in native-input zsh integration.

Run: uv run --no-project --python python3 test/native-input/test_zsh_bridge.py
No Ghostty build or user startup files are required. Each test has a private
temporary HOME/ZDOTDIR, terminal, and bridge directory; no user history is read.
"""

import os
import pty
import re
import select
import shlex
import signal
import subprocess
import tempfile
import time
import unittest
import uuid
from pathlib import Path


ADAPTER = (
    Path(__file__).resolve().parents[2]
    / "macos/Sources/Features/Command Input/native-input.zsh"
)
STARTUP = ADAPTER.with_name("native-input-startup.zsh")
TRIGGER = b"\x1b[99;1~"
COMPLETION_TRIGGER = b"\x1b[99;2~"
HISTORY_TRIGGER = b"\x1b[99;3~"


class Shell:
    def __init__(self, *, user_rc="", startup_files=None, login=False, zdotdir="home", native_ready=True,
                 shell_features=None):
        self.temporary = tempfile.TemporaryDirectory(prefix="ghostty-native-input-")
        self.root = Path(self.temporary.name)
        self.bridge = self.root / "bridge"
        self.bridge.mkdir(mode=0o700)
        (self.root / "work").mkdir()
        # A test-only finish hook records the exact accepted BUFFER so transport
        # fidelity is measured independently of shell parsing/history rewriting.
        (self.root / ".zshrc").write_text(
            "PS1='probe> '\nPS2='continue> '\nHISTFILE=/dev/null\nSAVEHIST=0\n"
            f"typeset -g _PROBE_DIR={shlex.quote(str(self.root))}\n"
            "_probe_finish() {\n"
            '  builtin print -rn -- "$BUFFER" > "$_PROBE_DIR/last-buffer"\n'
            "}\n"
            "zle -N zle-line-finish _probe_finish\n"
            + user_rc
        )
        for relative, content in (startup_files or {}).items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        # Exercise the same .zshenv dispatcher copied by the app. All startup
        # files are synthetic/private. Login and global startup behavior remain
        # the same as an ordinary zsh invocation.
        (self.bridge / ".zshenv").write_bytes(STARTUP.read_bytes())
        (self.bridge / "native-input.zsh").write_bytes(ADAPTER.read_bytes())
        environment = {
            "HOME": str(self.root), "ZDOTDIR": str(self.bridge),
            "PATINA_NATIVE_INPUT_DIR": str(self.bridge),
            "TERM": "xterm-256color", "PATH": "/usr/bin:/bin",
            "LC_ALL": "en_US.UTF-8",
        }
        if shell_features is not None:
            environment["GHOSTTY_SHELL_FEATURES"] = shell_features
        if zdotdir != "unset":
            environment["SPOOKY_ZSH_ZDOTDIR"] = "" if zdotdir == "empty" else str(self.root)
        self.pid, self.terminal = pty.fork()
        if self.pid == 0:
            os.chdir(self.root)
            os.execve(
                "/bin/zsh", ["zsh", "-il" if login else "-i"],
                environment,
            )
        os.set_blocking(self.terminal, False)
        self.output = bytearray()
        try:
            if native_ready:
                self.wait(lambda: self.state()[0] == "ready")
            else:
                self.wait(lambda: b"probe> " in self.output)
        except BaseException:
            self.close()
            raise

    def close(self):
        os.close(self.terminal)
        try:
            os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        os.waitpid(self.pid, 0)
        self.temporary.cleanup()

    def pump(self):
        if select.select([self.terminal], [], [], 0.02)[0]:
            try:
                self.output.extend(os.read(self.terminal, 65536))
            except OSError:
                pass

    def wait(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            self.pump()
        raise AssertionError(
            f"Timed out; state={self.state()!r}; receipt={self.receipt()!r}; "
            f"terminal={self.output.decode(errors='replace')!r}"
        )

    def state(self):
        try:
            return (self.bridge / "state").read_text().rstrip("\n").split("\t")
        except FileNotFoundError:
            return ["missing", "", ""]

    def receipt(self):
        try:
            return (self.bridge / "receipt").read_text().rstrip("\n").split("\t")
        except FileNotFoundError:
            return ["missing", "", ""]

    def stage(self, draft, generation=None, identifier=None):
        generation = generation or self.state()[1]
        identifier = identifier or str(uuid.uuid4())
        payload = draft.encode("utf-8") if isinstance(draft, str) else draft
        temporary = self.bridge / "request.next"
        temporary.write_bytes(f"{generation}\n{identifier}\n".encode() + payload)
        temporary.chmod(0o600)
        os.replace(temporary, self.bridge / "request")
        return identifier

    def trigger(self):
        os.write(self.terminal, TRIGGER)

    def stage_completion(self, draft, caret=None, generation=None, identifier=None):
        generation = generation or self.state()[1]
        identifier = identifier or str(uuid.uuid4())
        payload = draft.encode("utf-8") if isinstance(draft, str) else draft
        caret = len(payload) if caret is None else caret
        temporary = self.bridge / "completion-request.next"
        temporary.write_bytes(f"{generation}\n{identifier}\n{caret}\n".encode() + payload)
        temporary.chmod(0o600)
        os.replace(temporary, self.bridge / "completion-request")
        return identifier

    def completion_response(self, identifier):
        path = self.bridge / "completions" / identifier
        if not path.exists():
            return None
        result = {
            name: (path / name).read_text()
            for name in ("generation", "identifier", "status", "reason", "count", "truncated")
        }
        packed = path / "items-v1"
        if packed.exists():
            records = packed.read_bytes().split(b"\0")
            count = int(result["count"])
            assert len(records) == count * 2 + 1 and records[-1] == b""
            result["items"] = [
                {"cursor": int(records[index * 2]), "buffer": records[index * 2 + 1].decode("utf-8")}
                for index in range(count)
            ]
        else:
            result["items"] = [
                {
                    "buffer": (path / "items" / str(index) / "buffer").read_text(),
                    "cursor": int((path / "items" / str(index) / "cursor").read_text()),
                }
                for index in range(1, int(result["count"]) + 1)
            ]
        return result

    def complete(self, draft, caret=None, generation=None, identifier=None):
        identifier = self.stage_completion(draft, caret, generation, identifier)
        self.raw(COMPLETION_TRIGGER)
        self.wait(lambda: self.completion_response(identifier) is not None)
        return self.completion_response(identifier)

    def stage_history(self, generation=None, identifier=None):
        generation = generation or self.state()[1]
        identifier = identifier or str(uuid.uuid4())
        temporary = self.bridge / "history-request.next"
        temporary.write_text(f"{generation}\n{identifier}\n")
        temporary.chmod(0o600)
        os.replace(temporary, self.bridge / "history-request")
        return identifier

    def history_response(self, identifier):
        path = self.bridge / "histories" / identifier
        if not path.exists():
            return None
        result = {
            name: (path / name).read_text()
            for name in ("generation", "identifier", "status", "reason", "count", "truncated")
        }
        packed = (path / "items-v1").read_bytes()
        records = packed.split(b"\0")
        count = int(result["count"])
        assert len(records) == count + 1 and records[-1] == b""
        result["items"] = [entry.decode("utf-8") for entry in records[:-1]]
        return result

    def history(self, generation=None, identifier=None):
        identifier = self.stage_history(generation, identifier)
        self.raw(HISTORY_TRIGGER)
        self.wait(lambda: self.history_response(identifier) is not None)
        return self.history_response(identifier)

    def submit(self, draft, generation=None, identifier=None):
        generation = generation or self.state()[1]
        identifier = self.stage(draft, generation, identifier)
        self.trigger()
        self.wait(lambda: self.receipt()[1] == identifier)
        return identifier, generation

    def ready_after(self, generation):
        self.wait(lambda: self.state()[0] == "ready" and self.state()[1] != generation)

    def raw(self, data):
        os.write(self.terminal, data.encode("utf-8") if isinstance(data, str) else data)

    def result(self, name="result"):
        path = self.root / name
        return path.read_bytes() if path.exists() else None

    def metadata(self, block, name):
        path = self.bridge / "blocks" / block / name
        return path.read_bytes() if path.exists() else None

    def markers(self):
        self.pump()
        return [
            (match[0].decode(), match[1].decode())
            for match in re.findall(
                rb"\x1b\]133;([ABCD]);(?:[0-9]+;)?aid=([0-9]+-[0-9]+)\x07",
                self.output,
            )
        ]

    def osc(self, command):
        return re.findall(rb"\x1b\]" + str(command).encode() + rb";([^\x07\x1b]*)\x07", self.output)


@unittest.skipUnless(Path("/bin/zsh").exists(), "requires /bin/zsh")
class NativeInputBridgeTests(unittest.TestCase):
    def setUp(self):
        self.shell = Shell()
        self.addCleanup(self.shell.close)

    def test_completion_quotes_paths_and_keeps_visible_terminal_empty(self):
        shell = self.shell
        (shell.root / "alpha file").touch()
        (shell.root / "alpine").mkdir()
        before = shell.state()
        identifier = str(uuid.uuid4())
        shell.pump()
        output_start = len(shell.output)
        response = shell.complete("cat al", identifier=identifier)
        shell.pump()
        self.assertEqual(response["status"], "ok")
        self.assertEqual(response["identifier"], identifier)
        self.assertEqual(response["generation"], before[1])
        self.assertEqual(
            {item["buffer"] for item in response["items"]},
            {"cat alpha\\ file", "cat alpine/"},
        )
        self.assertEqual(shell.state(), before)
        self.assertNotIn(b"cat al", shell.output[output_start:])
        self.assertIsNone(shell.metadata(before[3], "input"))
        self.assertEqual(shell.metadata(before[3], "status"), b"editing")
        # The parent's actual BUFFER is still empty and the next command works.
        _, generation = shell.submit('print -rn -- after > "$_PROBE_DIR/result"')
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"after")

    def test_completion_uses_live_cwd_functions_aliases_and_variables(self):
        shell = self.shell
        (shell.root / "work" / "live file").touch()
        _, generation = shell.submit(
            "cd work\nexport PROBE_COMPLETION_VALUE=retained\n"
            "patina_function() { :; }\nalias patina_alias=true"
        )
        shell.ready_after(generation)
        response = shell.complete("cat liv")
        self.assertEqual(response["items"][0]["buffer"], "cat live\\ file ")
        response = shell.complete("patina_")
        self.assertTrue(
            {"patina_function", "patina_alias"}.issubset(
                {item["buffer"] for item in response["items"]}
            )
        )
        response = shell.complete("echo $PROBE_COMPLETION_V")
        self.assertEqual(response["items"][0]["buffer"], "echo $PROBE_COMPLETION_VALUE ")

    def test_completion_git_subcommands_and_live_compdef(self):
        shell = self.shell
        response = shell.complete("git che")
        self.assertIn("git checkout", {item["buffer"] for item in response["items"]})
        _, generation = shell.submit(
            "_patina_probe_candidates() { compadd -- 'first value' 'second value'; }\n"
            "compdef _patina_probe_candidates patina_probe"
        )
        shell.ready_after(generation)
        response = shell.complete("patina_probe ")
        self.assertEqual(
            {item["buffer"] for item in response["items"]},
            {"patina_probe first\\ value", "patina_probe second\\ value"},
        )

    def test_completion_multiline_unicode_and_middle_caret(self):
        shell = self.shell
        (shell.root / "日本語 file").touch()
        draft = 'echo "👩🏽‍💻"\ncat 日本 tail'
        caret = len('echo "👩🏽‍💻"\ncat 日本'.encode())
        before = shell.state()
        shell.pump()
        output_start = len(shell.output)
        response = shell.complete(draft, caret)
        self.assertEqual(response["status"], "ok")
        item = response["items"][0]
        self.assertEqual(item["buffer"], 'echo "👩🏽‍💻"\ncat 日本語\\ file  tail')
        self.assertEqual(item["cursor"], len('echo "👩🏽‍💻"\ncat 日本語\\ file '.encode()))
        self.assertEqual(shell.state(), before)
        shell.pump()
        self.assertNotIn(b"echo", shell.output[output_start:])

    def test_completion_inside_quotes_preserves_zsh_suffix(self):
        shell = self.shell
        (shell.root / "alpha file").touch()
        response = shell.complete('cat "alph')
        self.assertEqual(response["items"][0]["buffer"], 'cat "alpha file" ')
        self.assertEqual(response["items"][0]["cursor"], len('cat "alpha file" '))

    def test_completion_rejects_dynamic_syntax_without_executing_draft(self):
        shell = self.shell
        for draft in (
            'cat ./$(touch NEVER)/a',
            'cat ./`touch NEVER`/a',
            'cat <(touch NEVER)',
            'cat *(e:touch NEVER:)',
            'echo ${PROBE:=changed}',
            r"cat $'\x24\x28touch NEVER\x29'/a",
        ):
            with self.subTest(draft=draft):
                response = shell.complete(draft)
                self.assertEqual(response["status"], "rejected")
                self.assertEqual(response["reason"], "unsupported-dynamic-syntax")
                self.assertFalse((shell.root / "NEVER").exists())
        response = shell.complete('touch NEVER; cat zz_no_match')
        self.assertEqual(response["status"], "ok")
        self.assertFalse((shell.root / "NEVER").exists())

    def test_completion_validates_utf8_byte_caret_and_payload(self):
        shell = self.shell
        for draft, caret, reason in (
            ("echo 日本", 6, "invalid-caret"),
            ("echo", 5, "invalid-caret"),
            (b"cat \xff", 5, "invalid-utf8"),
            (b"cat a\0b", 5, "nul-in-draft"),
            ("cat a", "x", "malformed-caret"),
            ("x" * 1048577, 0, "oversized-draft"),
        ):
            with self.subTest(reason=reason):
                response = shell.complete(draft, caret)
                self.assertEqual(response["status"], "rejected")
                self.assertEqual(response["reason"], reason)

    def test_completion_reuses_prompt_worker_and_reclaims_rejected_claim(self):
        shell = self.shell
        _, generation = shell.submit(
            "_patina_probe_counter=0\n"
            "_patina_probe_completion() { compadd -- worker-$(( ++_patina_probe_counter )); }\n"
            "compdef _patina_probe_completion patina_probe"
        )
        shell.ready_after(generation)
        rejected = shell.complete(b"cat \xff", 5)
        self.assertEqual(rejected["reason"], "invalid-utf8")
        shell.wait(lambda: not list(shell.bridge.glob("completion-worker-request.*")))
        first = shell.complete("patina_probe ")
        second = shell.complete("patina_probe ")
        self.assertEqual(first["items"][0]["buffer"], "patina_probe worker-1 ")
        self.assertEqual(second["items"][0]["buffer"], "patina_probe worker-2 ")
        _, generation = shell.submit('print -rn -- "$_patina_probe_counter" > "$_PROBE_DIR/result"')
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"0")

    def test_completion_rejects_stale_and_terminal_buffer_requests(self):
        shell = self.shell
        old_generation = shell.state()[1]
        _, generation = shell.submit("true")
        shell.ready_after(generation)
        response = shell.complete("pri", generation=old_generation)
        self.assertEqual(response["reason"], "stale-generation")
        shell.raw("manual")
        shell.wait(lambda: shell.state()[0] == "terminal")
        response = shell.complete("pri")
        self.assertEqual(response["reason"], "nonempty-buffer")
        shell.raw(b"\x15")
        shell.wait(lambda: shell.state()[0] == "ready")
        self.assertTrue(shell.complete("prin")["items"])

    def test_completion_response_is_immutable_on_duplicate_trigger_or_uuid(self):
        shell = self.shell
        identifier = str(uuid.uuid4())
        response = shell.complete("prin", identifier=identifier)
        shell.raw(COMPLETION_TRIGGER)
        shell.pump()
        self.assertEqual(shell.completion_response(identifier), response)
        shell.stage_completion("git che", identifier=identifier)
        shell.raw(COMPLETION_TRIGGER)
        shell.wait(lambda: not (shell.bridge / "completion-request").exists())
        self.assertEqual(shell.completion_response(identifier), response)

    def test_prompt_transition_reclaims_unconsumed_completion_responses(self):
        shell = self.shell
        response = shell.complete("prin")
        root = shell.bridge / "completions"
        self.assertTrue((root / response["identifier"]).is_dir())
        staging = root / f".pending-{uuid.uuid4()}"
        staging.mkdir()
        (staging / "partial").write_text("unfinished")
        _, generation = shell.submit("true")
        shell.ready_after(generation)
        self.assertEqual(list(root.iterdir()), [])
        self.assertTrue(shell.complete("git che")["items"])

    def test_completion_inflight_duplicate_does_not_race_response_writer(self):
        shell = self.shell
        _, generation = shell.submit(
            "_patina_slow_candidates() {\n"
            '  print -rn -- started > "$_PROBE_DIR/completion-started"\n'
            "  sleep 0.15\n"
            "  compadd -- candidate\n"
            "}\ncompdef _patina_slow_candidates patina_slow"
        )
        shell.ready_after(generation)
        identifier = shell.stage_completion("patina_slow ")
        shell.raw(COMPLETION_TRIGGER)
        shell.wait(lambda: shell.result("completion-started") is not None)
        shell.stage_completion("git che", identifier=identifier)
        shell.raw(COMPLETION_TRIGGER)
        shell.wait(lambda: shell.completion_response(identifier) is not None)
        response = shell.completion_response(identifier)
        self.assertEqual(response["status"], "ok")
        self.assertEqual(response["items"][0]["buffer"], "patina_slow candidate ")

    def test_completion_newer_request_survives_inflight_completion(self):
        shell = self.shell
        _, generation = shell.submit(
            "_patina_slow_candidates() {\n"
            '  print -rn -- started > "$_PROBE_DIR/completion-started"\n'
            "  sleep 0.15\n"
            "  compadd -- candidate\n"
            "}\ncompdef _patina_slow_candidates patina_slow"
        )
        shell.ready_after(generation)
        first = shell.stage_completion("patina_slow ")
        shell.raw(COMPLETION_TRIGGER)
        shell.wait(lambda: shell.result("completion-started") is not None)
        second = shell.stage_completion("git che")
        shell.raw(COMPLETION_TRIGGER)
        shell.wait(lambda: shell.completion_response(second) is not None)
        self.assertEqual(shell.completion_response(first)["status"], "ok")
        self.assertIn(
            "git checkout", {item["buffer"] for item in shell.completion_response(second)["items"]}
        )

    def test_completion_caps_candidates_and_reports_truncation(self):
        shell = self.shell
        for index in range(205):
            (shell.root / f"candidate_{index:03}").touch()
        response = shell.complete("cat candidate_")
        self.assertEqual(response["count"], "200")
        self.assertEqual(response["truncated"], "1")
        self.assertEqual(len({item["buffer"] for item in response["items"]}), 200)

    def test_completion_bounds_total_result_bytes(self):
        shell = self.shell
        for index in range(100):
            (shell.root / f"candidate_{index:03}").touch()
        draft = "echo " + "x" * 100000 + "\ncat candidate_"
        response = shell.complete(draft)
        self.assertEqual(response["status"], "ok")
        self.assertEqual(response["truncated"], "1")
        total_bytes = sum(len(item["buffer"].encode()) for item in response["items"])
        self.assertLessEqual(total_bytes, 8388608)
        self.assertGreater(total_bytes, 8000000)
        self.assertLess(int(response["count"]), 100)

    def test_completion_continuation_and_foreground_requests_do_not_execute(self):
        shell = self.shell
        _, generation = shell.submit("if true; then")
        shell.wait(lambda: shell.state()[2] == "cont")
        response = shell.complete("prin")
        self.assertEqual(response["reason"], "not-primary-prompt")
        shell.raw(b"\x03")
        shell.wait(lambda: shell.state()[0] == "ready")
        old_generation = shell.state()[1]
        identifier = shell.stage_completion("prin")
        _, generation = shell.submit("read -r PROBE_READ")
        shell.wait(lambda: shell.state()[0] == "running")
        shell.raw("done\r")
        shell.ready_after(generation)
        shell.raw(COMPLETION_TRIGGER)
        shell.wait(lambda: shell.completion_response(identifier) is not None)
        response = shell.completion_response(identifier)
        self.assertEqual(response["reason"], "stale-generation")
        self.assertEqual(response["generation"], old_generation)

    def test_completion_hooks_run_but_parent_environment_is_preserved(self):
        shell = self.shell
        _, generation = shell.submit(
            "_patina_probe_candidates() {\n"
            '  print -rn -- hook > "$_PROBE_DIR/hook-ran"\n'
            "  PROBE_PARENT_VALUE=changed\n"
            "  compadd -- candidate\n"
            "}\n"
            "PROBE_PARENT_VALUE=original\n"
            "compdef _patina_probe_candidates patina_probe"
        )
        shell.ready_after(generation)
        response = shell.complete("patina_probe ")
        self.assertEqual(response["items"][0]["buffer"], "patina_probe candidate ")
        self.assertEqual(shell.result("hook-ran"), b"hook")
        _, generation = shell.submit(
            'print -rn -- "$PROBE_PARENT_VALUE" > "$_PROBE_DIR/result"'
        )
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"original")

    def test_completion_variable_values_are_not_reparsed_as_commands(self):
        shell = self.shell
        _, generation = shell.submit("PROBE_LITERAL='$(touch NEVER)'")
        shell.ready_after(generation)
        response = shell.complete("cat $PROBE_LITERAL/a")
        self.assertEqual(response["status"], "ok")
        self.assertFalse((shell.root / "NEVER").exists())

    def test_submitting_during_completion_retires_old_worker(self):
        shell = self.shell
        _, generation = shell.submit(
            "_patina_slow_candidates() {\n"
            '  print -rn -- started > "$_PROBE_DIR/completion-started"\n'
            "  sleep 0.4\n"
            "  compadd -- candidate\n"
            "}\ncompdef _patina_slow_candidates patina_slow"
        )
        shell.ready_after(generation)
        shell.stage_completion("patina_slow ")
        shell.raw(COMPLETION_TRIGGER)
        shell.wait(lambda: shell.result("completion-started") is not None)
        _, generation = shell.submit('print -rn -- submitted > "$_PROBE_DIR/result"')
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"submitted")
        self.assertFalse(list((shell.bridge / "completions").glob(".pending-*")))
        self.assertTrue(shell.complete("prin")["items"])

    def test_multiline_preserves_shell_environment(self):
        shell = self.shell
        _, generation = shell.submit(
            'export PROBE_VALUE=retained\ncd "$_PROBE_DIR/work"'
        )
        self.assertEqual(shell.receipt()[0], "accepted")
        shell.ready_after(generation)
        _, generation = shell.submit(
            'print -rn -- "$PROBE_VALUE|$PWD" > "$_PROBE_DIR/result"'
        )
        shell.ready_after(generation)
        self.assertEqual(shell.result(), f"retained|{shell.root / 'work'}".encode())

    def test_nested_process_does_not_inherit_bridge_environment(self):
        shell = self.shell
        _, generation = shell.submit(
            "zsh -f -c 'print -rn -- ${+PATINA_NATIVE_INPUT_DIR}' "
            '> "$_PROBE_DIR/result"'
        )
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"0")

    def test_heredoc_unicode_and_trailing_newlines_are_exact(self):
        shell = self.shell
        draft = (
            'cat > "$_PROBE_DIR/result" <<\'PROBE_EOF\'\n'
            'first line\nsecond "quoted" line\n日本語 👩🏽‍💻 é\nPROBE_EOF\n\n'
        )
        _, generation = shell.submit(draft)
        shell.ready_after(generation)
        self.assertEqual(shell.result("last-buffer"), draft.encode())
        self.assertEqual(
            shell.result(), 'first line\nsecond "quoted" line\n日本語 👩🏽‍💻 é\n'.encode()
        )

    def test_accepted_prompt_never_republishes_ready_during_final_redraw(self):
        shell = self.shell
        # Record the real published state after each call. This observes ZLE's
        # actual pre-redraw/line-finish ordering without adding a user widget.
        _, generation = shell.submit(
            'functions[_probe_publish]=$functions[_patina_native_publish]\n'
            '_patina_native_publish() { _probe_publish "$@"; '
            'builtin print -r -- "$_patina_native_last_state" >> "$_PROBE_DIR/states"; }'
        )
        shell.ready_after(generation)
        for draft in ("", ":", "echo )"):
            with self.subTest(draft=draft):
                (shell.root / "states").write_bytes(b"")
                _, generation = shell.submit(draft)
                shell.ready_after(generation)
                shell.wait(lambda: shell.state()[1].encode() in (shell.result("states") or b""))
                records = [line.split(b"\t") for line in shell.result("states").splitlines()]
                old_prompt = [record[0] for record in records if record[1].decode() == generation]
                self.assertIn(b"running", old_prompt)
                self.assertNotIn(b"ready", old_prompt)
                self.assertEqual(shell.state()[0], "ready")

    def test_accepted_generation_does_not_suppress_later_terminal_edits_or_retry(self):
        shell = self.shell
        _, generation = shell.submit("if true; then")
        shell.wait(lambda: shell.state()[2] == "cont")
        self.assertNotEqual(shell.state()[1], generation)
        shell.raw(b"\x03")
        shell.ready_after(generation)
        current = shell.state()[1]
        shell.raw("echo pending")
        shell.wait(lambda: shell.state()[0] == "terminal")
        shell.raw(b"\x15")  # Kill the ordinary terminal line without accepting it.
        shell.wait(lambda: shell.state()[0] == "ready")
        self.assertEqual(shell.state()[1], current)
        shell.submit(":", generation=generation)
        self.assertEqual(shell.receipt()[2], "stale-generation")
        self.assertEqual(shell.state()[0], "ready")
        _, generation = shell.submit(":")
        shell.ready_after(generation)
        self.assertEqual(shell.receipt()[0], "accepted")

    def test_incomplete_input_yields_to_terminal_continuation(self):
        shell = self.shell
        block = shell.state()[3]
        _, generation = shell.submit("if true; then")
        shell.wait(lambda: shell.state()[0] == "terminal" and shell.state()[2] == "cont")
        self.assertNotEqual(shell.state()[1], generation)
        self.assertEqual(shell.state()[3], block)
        self.assertEqual(shell.receipt()[0], "accepted")
        shell.submit('print -r -- WRONG > "$_PROBE_DIR/result"')
        self.assertEqual(shell.receipt()[2], "not-primary-prompt")
        shell.raw('print -rn -- continued > "$_PROBE_DIR/result"\rfi\r')
        shell.wait(lambda: shell.result() == b"continued")
        shell.wait(lambda: shell.state()[0] == "ready")
        self.assertNotEqual(shell.state()[3], block)
        self.assertEqual(shell.metadata(block, "input"), b"if true; then")
        self.assertIn(b"continued", shell.metadata(block, "executed-input"))
        self.assertEqual(shell.metadata(block, "status"), b"completed")

    def test_primary_block_reserves_two_header_rows_and_finishes_in_order(self):
        shell = self.shell
        self.assertEqual(len(shell.state()), 4)
        block = shell.state()[3]
        _, generation = shell.submit("true")
        shell.ready_after(generation)
        next_block = shell.state()[3]
        self.assertNotEqual(next_block, block)
        markers = shell.markers()
        for marker in "ACD":
            self.assertEqual(markers.count((marker, block)), 1)
        self.assertLess(markers.index(("A", block)), markers.index(("B", block)))
        self.assertLess(markers.index(("B", block)), markers.index(("C", block)))
        self.assertLess(markers.index(("C", block)), markers.index(("D", block)))
        self.assertLess(markers.index(("D", block)), markers.index(("A", next_block)))
        header_start = f"\x1b]133;A;aid={block}\x07".encode()
        self.assertIn(header_start + b"\r\n\r\n", shell.output)
        self.assertNotIn(header_start + b"\r\n\r\n\r\n", shell.output)
        self.assertEqual(shell.metadata(block, "status"), b"completed")
        self.assertEqual(shell.metadata(block, "exit-status"), b"0")
        self.assertEqual(shell.metadata(next_block, "status"), b"editing")

    def test_block_metadata_preserves_original_cwd_and_failure_status(self):
        shell = self.shell
        block = shell.state()[3]
        draft = 'cd "$_PROBE_DIR/work"\nfalse'
        _, generation = shell.submit(draft)
        shell.ready_after(generation)
        self.assertEqual(shell.metadata(block, "cwd"), str(shell.root.resolve()).encode())
        self.assertEqual(shell.metadata(shell.state()[3], "cwd"), str(shell.root / "work").encode())
        self.assertEqual(shell.metadata(block, "input"), draft.encode())
        self.assertEqual(shell.metadata(block, "exit-status"), b"1")
        self.assertGreater(float(shell.metadata(block, "started-wall")), 0)
        self.assertGreater(float(shell.metadata(block, "finished-wall")), 0)

    def test_submitted_command_occupies_one_transcript_line(self):
        shell = self.shell
        draft = "export PROBE_ECHO_ONCE=unique_value"
        block = shell.state()[3]
        _, generation = shell.submit(draft)
        shell.ready_after(generation)
        shell.pump()
        first_input = shell.output.index(f"\x1b]133;B;aid={block}\x07".encode())
        output_start = shell.output.index(f"\x1b]133;C;aid={block}\x07".encode())
        input_bytes = shell.output[first_input:output_start]
        # ZLE may redraw the short command repeatedly using CR/erase sequences.
        # It must commit only one terminal row, not print duplicate commands.
        self.assertIn(draft.encode(), input_bytes)
        self.assertEqual(input_bytes.count(b"\n"), 1)

    def test_empty_input_without_preexec_still_completes_block(self):
        shell = self.shell
        # Interactive comments are opt-in in zsh. An empty draft is a true
        # no-preexec case under the starter shell's unchanged option defaults.
        block = shell.state()[3]
        _, generation = shell.submit("")
        shell.ready_after(generation)
        self.assertEqual(shell.metadata(block, "input"), b"")
        self.assertEqual(shell.metadata(block, "status"), b"completed")
        self.assertEqual(shell.metadata(block, "exit-status"), b"0")
        self.assertIsNone(shell.metadata(block, "started-wall"))
        self.assertNotIn(("C", block), shell.markers())
        self.assertIn(("D", block), shell.markers())

    def test_syntax_error_without_preexec_completes_block(self):
        shell = self.shell
        block = shell.state()[3]
        _, generation = shell.submit("echo )")
        shell.ready_after(generation)
        self.assertEqual(shell.metadata(block, "status"), b"completed")
        self.assertGreater(int(shell.metadata(block, "exit-status")), 0)
        self.assertIsNone(shell.metadata(block, "started-wall"))
        self.assertIn(("D", block), shell.markers())

    def test_cancelled_continuation_finishes_same_block(self):
        shell = self.shell
        block = shell.state()[3]
        _, generation = shell.submit("if true; then")
        shell.wait(lambda: shell.state()[2] == "cont")
        self.assertEqual(shell.state()[3], block)
        shell.raw(b"\x03")
        shell.ready_after(generation)
        self.assertEqual(shell.metadata(block, "status"), b"completed")
        self.assertEqual(shell.metadata(block, "exit-status"), b"130")
        self.assertIsNone(shell.metadata(block, "started-wall"))

    def test_terminal_entered_command_uses_same_block_metadata(self):
        shell = self.shell
        block = shell.state()[3]
        generation = shell.state()[1]
        shell.raw("false\r")
        shell.ready_after(generation)
        self.assertEqual(shell.metadata(block, "input"), b"false")
        self.assertEqual(shell.metadata(block, "exit-status"), b"1")
        self.assertIn(("C", block), shell.markers())

    def test_normal_shell_exit_finalizes_last_block(self):
        shell = self.shell
        block = shell.state()[3]
        shell.submit("exit 7")
        shell.wait(lambda: shell.state()[0] == "exited")
        self.assertEqual(shell.metadata(block, "status"), b"completed")
        self.assertEqual(shell.metadata(block, "exit-status"), b"7")
        self.assertIn(("D", block), shell.markers())

    def test_stale_generation_is_rejected(self):
        shell = self.shell
        generation = shell.state()[1]
        shell.stage('print -r -- WRONG > "$_PROBE_DIR/result"', generation)
        shell.raw("true\r")
        shell.ready_after(generation)
        shell.trigger()
        shell.wait(lambda: shell.receipt()[0] == "rejected")
        self.assertEqual(shell.receipt()[2], "stale-generation")
        self.assertIsNone(shell.result())

    def test_duplicate_request_and_duplicate_trigger_do_not_execute_twice(self):
        shell = self.shell
        command = 'print -r -- once >> "$_PROBE_DIR/result"'
        identifier, generation = shell.submit(command)
        shell.ready_after(generation)
        original_receipt = shell.receipt()
        shell.trigger()
        shell.pump()
        self.assertEqual(shell.receipt(), original_receipt)
        shell.submit(command, identifier=identifier)
        shell.wait(lambda: shell.receipt()[0] == "rejected")
        self.assertEqual(shell.receipt()[2], "duplicate-request")
        self.assertEqual(shell.result(), b"once\n")

    def test_partial_terminal_input_is_not_overwritten(self):
        shell = self.shell
        shell.raw("echo keep-this")
        shell.wait(lambda: shell.state()[0] == "terminal")
        shell.submit('print -r -- WRONG > "$_PROBE_DIR/result"')
        self.assertEqual(shell.receipt()[2], "nonempty-buffer")
        shell.raw("\r")
        shell.wait(lambda: shell.state()[0] == "ready")
        self.assertEqual(shell.result("last-buffer"), b"echo keep-this")
        self.assertIsNone(shell.result())

    def test_read_keeps_terminal_ownership_and_queued_request_becomes_stale(self):
        shell = self.shell
        _, generation = shell.submit(
            'print -r -- waiting > "$_PROBE_DIR/waiting"\n'
            'read -r answer\nprint -rn -- "$answer" > "$_PROBE_DIR/result"'
        )
        shell.wait(lambda: shell.result("waiting") is not None)
        self.assertEqual(shell.state()[0], "running")
        identifier = shell.stage('print -r -- WRONG >> "$_PROBE_DIR/result"', generation)
        # The UI must not send a trigger while state=running. Leave the file
        # queued, answer the foreground program normally, then probe rejection.
        shell.raw("ordinary terminal input\r")
        shell.ready_after(generation)
        shell.trigger()
        shell.wait(lambda: shell.receipt()[1] == identifier)
        self.assertEqual(shell.receipt()[2], "stale-generation")
        self.assertEqual(shell.result(), b"ordinary terminal input")

    def test_raw_mode_foreground_program_retains_terminal_input(self):
        shell = self.shell
        _, generation = shell.submit(
            'stty -echo -icanon min 1 time 0\n'
            'print -r -- waiting > "$_PROBE_DIR/waiting"\n'
            'dd bs=1 count=1 of="$_PROBE_DIR/result" 2>/dev/null\nstty sane'
        )
        shell.wait(lambda: shell.result("waiting") is not None)
        self.assertEqual(shell.state()[0], "running")
        shell.raw(b"q")
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"q")

    def test_nul_payload_is_rejected(self):
        shell = self.shell
        shell.submit(b"echo do-not-run\0echo also-do-not-run")
        self.assertEqual(shell.receipt()[2], "nul-in-draft")
        self.assertEqual(shell.state()[0], "ready")

    def test_oversized_payload_is_rejected(self):
        shell = self.shell
        shell.stage(b"x" * (1048576 + 300))
        shell.trigger()
        shell.wait(lambda: shell.receipt()[0] == "rejected")
        self.assertEqual(shell.receipt()[2], "oversized-request")
        self.assertEqual(shell.state()[0], "ready")


@unittest.skipUnless(Path("/bin/zsh").exists(), "requires /bin/zsh")
class NativeBranchMetadataTests(unittest.TestCase):
    def setUp(self):
        self.shell = Shell()
        self.addCleanup(self.shell.close)

    def git(self, *arguments, cwd=None):
        return subprocess.check_output(
            ["/usr/bin/git", "-C", str(cwd or self.shell.root), *arguments],
            env={"HOME": str(self.shell.root), "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"},
            stderr=subprocess.DEVNULL,
        ).decode().strip()

    def refresh(self, command="builtin :"):
        _, generation = self.shell.submit(command)
        self.shell.ready_after(generation)
        return self.shell.metadata(self.shell.state()[3], "branch").decode()

    def initialize(self, directory=None):
        self.git("init", "-q", "-b", "main", cwd=directory)
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-q", "--allow-empty", "-m", "fixture", cwd=directory)

    def test_branch_reads_new_repository_and_live_branch_changes_without_cache(self):
        self.assertEqual(self.refresh(), "")
        self.initialize()
        self.assertEqual(self.refresh(), "main")
        self.git("checkout", "-q", "-b", "feature/café")
        self.assertEqual(self.refresh(), "feature/café")
        self.git("checkout", "-q", "--detach")
        self.assertEqual(self.refresh(), "")
        self.git("checkout", "-q", "main")
        self.assertEqual(self.refresh(), "main")

    def test_branch_follows_nested_repository_and_physical_cwd(self):
        self.initialize()
        nested = self.shell.root / "work"
        (self.shell.root / "linked-work").symlink_to(nested, target_is_directory=True)
        self.assertEqual(self.refresh("cd linked-work"), "main")
        self.git("init", "-q", "-b", "nested", cwd=nested)
        self.assertEqual(self.refresh(), "nested")
        self.assertEqual(self.refresh("cd .."), "main")

    def test_branch_resolves_worktree_gitdir_commondir_and_detached_head(self):
        self.initialize()
        linked = self.shell.root / "linked"
        self.git("worktree", "add", "-q", "-b", "linked-branch", str(linked))
        self.assertEqual(self.refresh("cd linked"), "linked-branch")
        self.git("checkout", "-q", "--detach", cwd=linked)
        self.assertEqual(self.refresh(), "")
        self.git("checkout", "-q", "-b", "linked-next", cwd=linked)
        self.assertEqual(self.refresh(), "linked-next")
        self.assertEqual(self.refresh("cd .."), "main")

    def test_branch_resolves_relative_gitfile_and_symbolic_ref_chain(self):
        self.git("init", "-q", "-b", "main", "--separate-git-dir", str(self.shell.root / "git-data"),
                 str(self.shell.root / "work"))
        (self.shell.root / "work/.git").write_text("gitdir: ../git-data\n")
        self.assertEqual(self.refresh("cd work"), "main")
        self.git("symbolic-ref", "refs/heads/alias", "refs/heads/main", cwd=self.shell.root / "work")
        self.git("symbolic-ref", "HEAD", "refs/heads/alias", cwd=self.shell.root / "work")
        self.assertEqual(self.refresh(), "main")

    def test_branch_explicit_git_environment_uses_git_fallback(self):
        self.initialize(self.shell.root / "work")
        self.assertEqual(self.refresh(), "")
        self.assertEqual(self.refresh('export GIT_DIR="$HOME/work/.git"'), "main")
        self.assertEqual(self.refresh("unset GIT_DIR"), "")


@unittest.skipUnless(Path("/bin/zsh").exists(), "requires /bin/zsh")
class NativeHistoryBridgeTests(unittest.TestCase):
    def shell(self, **options):
        shell = Shell(**options)
        self.addCleanup(shell.close)
        return shell

    def test_history_preserves_exact_multiline_unicode_and_chronology(self):
        older = "echo older"
        newest = "printf 'café 👻\\n'\n\tprintf 'two'  \n"
        shell = self.shell(user_rc="HISTSIZE=2048\n" + "\n".join(
            f"builtin print -sr -- {shlex.quote(entry)}" for entry in [older, newest]
        ) + "\n")
        before = shell.state()
        identifier = str(uuid.uuid4())
        response = shell.history(identifier=identifier)
        self.assertEqual(response["status"], "ok")
        self.assertEqual(response["generation"], before[1])
        self.assertEqual(response["identifier"], identifier)
        self.assertEqual(response["items"], [newest, older])
        self.assertEqual(response["truncated"], "0")
        self.assertEqual(shell.state(), before)
        self.assertIsNone(shell.metadata(before[3], "input"))

    def test_history_uses_entries_loaded_by_normal_user_configuration(self):
        shell = self.shell(
            user_rc='HISTFILE="$HOME/previous-history"\nHISTSIZE=100\nSAVEHIST=100\n',
            startup_files={"previous-history": ": 1700000000:0;echo previous café\n"
                ": 1700000001:0;printf 'first'\\\nprintf 'second'\n"},
        )
        self.assertEqual(shell.history()["items"], [
            "printf 'first'\nprintf 'second'", "echo previous café",
        ])
        # Snapshot reads the live history, not the file: changing the file after
        # startup must not silently import commands absent from this shell.
        (shell.root / "previous-history").write_text("echo never imported\n")
        self.assertNotIn("echo never imported", shell.history()["items"])

    def test_history_keeps_zle_buffer_cursor_event_and_options_unchanged(self):
        shell = self.shell(user_rc="HISTSIZE=100\n"
            "builtin print -sr -- 'echo fixture'\n"
            "_probe_history_count=0\n"
            "_probe_history_state() {\n"
            '  builtin print -rn -- "$BUFFER"$\'\\0\'"$CURSOR"$\'\\0\'"$HISTNO"'
            '$\'\\0\'"$HISTCMD"$\'\\0\'"${options[ksharrays]}" > "$HOME/history-state"\n'
            '  (( ++_probe_history_count )); print -rn -- "$_probe_history_count" > "$HOME/history-state-count"\n'
            "}\n"
            "zle -N _probe_history_state\n"
            "bindkey $'\\e[99;4~' _probe_history_state\n"
            "setopt ksh_arrays no_unset\n")
        shell.raw(b"\x1b[99;4~")
        shell.wait(lambda: shell.result("history-state-count") == b"1")
        before = shell.result("history-state")
        first = shell.history()
        shell.raw(b"\x1b[99;4~")
        shell.wait(lambda: shell.result("history-state-count") == b"2")
        self.assertEqual(shell.result("history-state"), before)
        self.assertEqual(shell.history()["items"], first["items"])
        _, generation = shell.submit('print -rn -- after > "$HOME/result"')
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"after")
        self.assertEqual(shell.history()["items"][0], 'print -rn -- after > "$HOME/result"')

    def test_history_rejects_stale_generation_terminal_buffer_and_continuation(self):
        shell = self.shell()
        old_generation = shell.state()[1]
        _, generation = shell.submit("true")
        shell.ready_after(generation)
        self.assertEqual(shell.history(generation=old_generation)["reason"], "stale-generation")
        shell.raw("echo unfinished")
        shell.wait(lambda: shell.state()[0] == "terminal")
        self.assertEqual(shell.history()["reason"], "nonempty-buffer")
        shell.raw(b"\x15")
        shell.wait(lambda: shell.state()[0] == "ready")
        _, generation = shell.submit("for item in")
        shell.wait(lambda: shell.state()[2] == "cont")
        self.assertEqual(shell.history()["reason"], "not-primary-prompt")
        shell.raw(b"\x03")
        shell.ready_after(generation)

    def test_history_caps_recent_events_and_packed_bytes(self):
        shell = self.shell(user_rc="HISTSIZE=2000\n"
            'for (( index=0; index<1105; ++index )); do print -sr -- "echo event-$index"; done\n')
        response = shell.history()
        self.assertEqual(len(response["items"]), 1000)
        self.assertEqual(response["items"][0], "echo event-1104")
        self.assertEqual(response["items"][-1], "echo event-105")
        self.assertEqual(response["truncated"], "1")

        large = self.shell(user_rc="HISTSIZE=100\n"
            "text=${(l:600000::x:)}\n"
            'print -sr -- "older $text"\nprint -sr -- "newer $text"\n'
            "oversized=${(l:1048577::z:)}\nprint -sr -- \"$oversized\"\n")
        response = large.history()
        self.assertEqual(len(response["items"]), 1)
        self.assertEqual(response["items"][0], "newer " + "x" * 600000)
        self.assertEqual(response["truncated"], "1")
        packed = large.bridge / "histories" / response["identifier"] / "items-v1"
        self.assertLessEqual(packed.stat().st_size, 1048576)

    def test_history_keeps_chronological_duplicates_and_respects_storage_options(self):
        shell = self.shell(user_rc="HISTSIZE=100\nsetopt hist_find_no_dups\n"
            "print -sr -- one\nprint -sr -- two\nprint -sr -- one\n")
        # HIST_FIND_NO_DUPS changes search widgets, not ordinary .up-history.
        self.assertEqual(shell.history()["items"], ["one", "two", "one"])
        deduplicating = self.shell(user_rc="HISTSIZE=100\nsetopt hist_ignore_all_dups\n")
        for draft in [": one", ": two", ": one"]:
            _, generation = deduplicating.submit(draft)
            deduplicating.ready_after(generation)
        self.assertEqual(deduplicating.history()["items"], [": one", ": two"])

    def test_history_sparse_event_numbers_preserve_old_live_entries(self):
        shell = self.shell(user_rc="HISTSIZE=2\n"
            'for (( index=0; index<2050; ++index )); do print -sr -- "seed-$index"; done\n'
            "HISTSIZE=10000\nsetopt hist_ignore_all_dups\n")
        for command in [": ancient", *([": repeated"] * 40), ": newest"]:
            _, generation = shell.submit(command)
            shell.ready_after(generation)
        self.assertEqual(shell.history()["items"][:3], [": newest", ": repeated", ": ancient"])

    def test_history_large_dense_event_numbers_return_exact_recent_window(self):
        shell = self.shell(user_rc="HISTSIZE=12000\n"
            'for (( index=0; index<5000; ++index )); do print -sr -- "dense-$index"; done\n')
        response = shell.history()
        self.assertEqual(response["items"], [f"dense-{index}" for index in range(4999, 3999, -1)])
        self.assertEqual(response["truncated"], "1")

    def test_history_queued_during_foreground_read_is_rejected_at_next_prompt(self):
        shell = self.shell()
        _, generation = shell.submit('read -r answer; print -rn -- "$answer" > "$HOME/result"')
        shell.wait(lambda: shell.state()[0] == "running")
        identifier = shell.stage_history(generation=generation)
        self.assertIsNone(shell.history_response(identifier))
        shell.raw("foreground input\r")
        shell.ready_after(generation)
        shell.raw(HISTORY_TRIGGER)
        shell.wait(lambda: shell.history_response(identifier) is not None)
        self.assertEqual(shell.history_response(identifier)["reason"], "stale-generation")
        self.assertEqual(shell.result(), b"foreground input")

    def test_history_filters_control_and_invalid_utf8_without_execution(self):
        harmless = 'echo $(touch "$HOME/should-not-exist")'
        shell = self.shell(user_rc="HISTSIZE=100\n"
            f"print -sr -- {shlex.quote(harmless)}\n"
            "print -sr -- ''\n"
            "print -sr -- $'bad\\x1bcontrol'\n"
            "print -sr -- $'bad\\0nul'\n"
            "print -sr -- $'bad\\x80utf8'\n"
            "print -sr -- $'bad\\xc3'\n")
        response = shell.history()
        self.assertEqual(response["items"], [harmless])
        self.assertEqual(response["truncated"], "1")
        self.assertFalse((shell.root / "should-not-exist").exists())

    def test_history_duplicate_requests_and_prompt_changes_reclaim_storage(self):
        shell = self.shell(user_rc="HISTSIZE=100\nprint -sr -- 'echo fixture'\n")
        first = shell.history()
        identifier = first["identifier"]
        self.assertEqual(shell.history(identifier=identifier), first)
        second = shell.history()
        self.assertFalse((shell.bridge / "histories" / identifier).exists())
        self.assertTrue((shell.bridge / "histories" / second["identifier"]).exists())
        self.assertEqual(shell.history(identifier=identifier)["reason"], "duplicate-request")
        self.assertEqual(len(list((shell.bridge / "histories").iterdir())), 1)
        _, generation = shell.submit("true")
        shell.ready_after(generation)
        self.assertEqual(list((shell.bridge / "histories").iterdir()), [])
        self.assertEqual(shell.history(generation=first["generation"])["reason"], "stale-generation")
        self.assertFalse(list(shell.bridge.glob("history-consumed.*")))

    def test_history_rejects_extra_request_payload_and_oversize(self):
        shell = self.shell()
        identifier = shell.stage_history()
        with (shell.bridge / "history-request").open("ab") as request:
            request.write(b"unexpected")
        shell.raw(HISTORY_TRIGGER)
        shell.wait(lambda: shell.history_response(identifier) is not None)
        self.assertEqual(shell.history_response(identifier)["reason"], "malformed-request")
        (shell.bridge / "history-request").write_bytes(b"x" * 259)
        shell.raw(HISTORY_TRIGGER)
        shell.wait(lambda: shell.history_response("-") is not None)
        self.assertEqual(shell.history_response("-")["reason"], "oversized-request")


@unittest.skipUnless(Path("/bin/zsh").exists(), "requires /bin/zsh")
class UserStartupCompatibilityTests(unittest.TestCase):
    def shell(self, **options):
        shell = Shell(**options)
        self.addCleanup(shell.close)
        return shell

    def test_cwd_and_titles_follow_prompt_and_foreground_cd_without_duplicate_blocks(self):
        shell = self.shell(
            shell_features="cursor:blink,path,title",
            user_rc='_probe_chpwd() { print -r -- "$PWD" >> "$HOME/chpwd-ran"; }\n'
            'chpwd_functions+=(_probe_chpwd)\n',
        )
        shell.wait(lambda: shell.osc(7) and shell.osc(2))
        self.assertTrue(shell.osc(7)[-1].endswith(str(shell.root.resolve()).encode()))
        # The PTY's initial getcwd may resolve macOS /var's symlink, while
        # HOME preserves its logical spelling. Match upstream's short title.
        self.assertTrue(shell.osc(2)[-1].endswith(shell.root.name.encode()))
        block = shell.state()[3]
        draft = 'cd "$_PROBE_DIR/work"; read -r PROBE_DONE'
        _, generation = shell.submit(draft)
        expected = str(shell.root / "work").encode()
        shell.wait(lambda: shell.result("chpwd-ran") is not None and
                   any(value.endswith(expected) for value in shell.osc(7)))
        self.assertEqual(shell.state()[0], "running")
        self.assertEqual(shell.osc(2)[-1], draft.encode())
        shell.raw("done\r")
        shell.ready_after(generation)
        shell.wait(lambda: shell.osc(2)[-1] == b"~/work")
        self.assertTrue(shell.osc(7)[-1].endswith(expected))
        self.assertEqual(shell.result("chpwd-ran"), expected + b"\n")
        for marker in ("A", "C", "D"):
            self.assertEqual(shell.markers().count((marker, block)), 1)

    def test_prompt_restores_cwd_after_program_report_and_preserves_failed_exit_status(self):
        shell = self.shell(shell_features="title")
        shell.wait(lambda: shell.osc(2))
        initial_title = shell.osc(2)[-1]
        block = shell.state()[3]
        _, generation = shell.submit("printf '\\033]7;kitty-shell-cwd://program/fake\\a'; false")
        shell.ready_after(generation)
        shell.wait(lambda: shell.osc(7) and shell.osc(7)[-1].endswith(str(shell.root.resolve()).encode()))
        self.assertIn(b"kitty-shell-cwd://program/fake", shell.osc(7))
        self.assertNotEqual(shell.osc(7)[-1], b"kitty-shell-cwd://program/fake")
        self.assertEqual(shell.metadata(block, "exit-status"), b"1")
        self.assertEqual(shell.osc(2)[-1], initial_title)

    def test_disabled_title_feature_does_not_disable_cwd_reporting(self):
        for features in (None, "", "cursor:blink,path", "notitle"):
            with self.subTest(features=features):
                shell = self.shell(shell_features=features)
                _, generation = shell.submit('cd "$_PROBE_DIR/work"')
                shell.ready_after(generation)
                shell.wait(lambda: shell.osc(7) and shell.osc(7)[-1].endswith(b"/work"))
                self.assertEqual(shell.osc(2), [])

    def test_cwd_and_command_titles_strip_control_bytes_but_keep_literal_paths(self):
        shell = self.shell(shell_features="title", user_rc="HOST=$'host\\a\\e]52;c;HOST\\a'\n")
        name = "quarter\\report café %\x07\x1b]52;c;PATH\x07"
        directory = shell.root / name
        directory.mkdir()
        draft = "cd " + shlex.quote(str(directory))
        _, generation = shell.submit(draft)
        shell.ready_after(generation)
        expected = b"kitty-shell-cwd://host]52;c;HOST" + str(directory).encode().replace(b"\x07", b"").replace(b"\x1b", b"")
        shell.wait(lambda: expected in shell.osc(7))
        self.assertIn(draft.encode().replace(b"\x07", b"").replace(b"\x1b", b""), shell.osc(2))
        self.assertEqual(shell.osc(52), [])
        self.assertEqual(shell.metadata(shell.state()[3], "cwd"), str(directory).encode())

    def test_late_user_prompt_chdir_refreshes_cwd_and_prompt_title(self):
        shell = self.shell(
            shell_features="title",
            user_rc='_probe_first_prompt() { cd "$HOME/work"; '
            'precmd_functions=(${precmd_functions:#_probe_first_prompt}); }\n'
            'precmd_functions+=(_probe_first_prompt)\n',
        )
        shell.wait(lambda: shell.osc(2) and shell.osc(2)[-1] == b"~/work")
        self.assertTrue(shell.osc(7)[-1].endswith(b"/work"))
        self.assertEqual(shell.metadata(shell.state()[3], "cwd"), str(shell.root / "work").encode())

    def test_completion_worker_chdir_keeps_user_hooks_without_publishing_terminal_cwd(self):
        shell = self.shell(
            shell_features="title",
            user_rc='autoload -Uz compinit; compinit -i -D\n'
            '_probe_chpwd() { print -rn -- "$PWD" > "$HOME/worker-chpwd"; }\n'
            'chpwd_functions+=(_probe_chpwd)\n'
            '_probe_completion() { cd "$HOME/work"; compadd -- candidate; }\n'
            'compdef _probe_completion probe\n',
        )
        shell.pump()
        before = shell.osc(7), shell.osc(2), shell.state()
        response = shell.complete("probe ")
        self.assertEqual(response["items"][0]["buffer"], "probe candidate ")
        self.assertEqual(shell.result("worker-chpwd"), str(shell.root / "work").encode())
        shell.pump()
        # ZLE can erase/redraw its empty input after the transport widget;
        # neither cwd/title announcements nor ownership may change.
        self.assertEqual((shell.osc(7), shell.osc(2), shell.state()), before)

    def test_login_loads_user_files_once_in_normal_order(self):
        shell = self.shell(
            login=True,
            startup_files={
                ".zshenv": 'print -r -- env >> "$HOME/startup-order"\n'
                'export PROBE_ENVIRONMENT=from-zshenv\n'
                'print -rn -- "${+PATINA_NATIVE_INPUT_DIR}|${+SPOOKY_ZSH_ZDOTDIR}" '
                '> "$HOME/startup-markers"\n',
                ".zprofile": 'print -r -- profile >> "$HOME/startup-order"\n'
                'export PROBE_PROFILE=from-profile\n',
                ".zlogin": 'print -r -- login >> "$HOME/startup-order"\n'
                'export PROBE_LOGIN=from-login\n',
            },
            user_rc='print -r -- rc >> "$HOME/startup-order"\n'
            '_probe_user_precmd() { print -r -- precmd >> "$HOME/startup-order"; }\n'
            'precmd_functions+=(_probe_user_precmd)\n'
            '_probe_user_init() { print -r -- init >> "$HOME/startup-order"; }\n'
            'zle -N zle-line-init _probe_user_init\n',
        )
        self.assertEqual(shell.result("startup-order"), b"env\nprofile\nrc\nlogin\nprecmd\ninit\n")
        self.assertEqual(shell.result("startup-markers"), b"0|0")
        _, generation = shell.submit(
            'print -rn -- "$PROBE_ENVIRONMENT|$PROBE_PROFILE|$PROBE_LOGIN|${options[login]}" '
            '> "$_PROBE_DIR/result"'
        )
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"from-zshenv|from-profile|from-login|on")
        self.assertEqual(shell.result("startup-order").splitlines().count(b"env"), 1)
        self.assertTrue(shell.complete("prin")["items"])

    def test_nonlogin_skips_profile_and_login_but_keeps_rc_environment(self):
        shell = self.shell(
            startup_files={
                ".zshenv": 'print -r -- env >> "$HOME/startup-order"\n',
                ".zprofile": 'print -r -- WRONG-profile >> "$HOME/startup-order"\n',
                ".zlogin": 'print -r -- WRONG-login >> "$HOME/startup-order"\n',
            },
            user_rc='print -r -- rc >> "$HOME/startup-order"\n'
            'export PATH="$HOME/custom-bin:$PATH"\n'
            'alias patina_startup_alias="print -rn -- configured"\n'
            'alias patina_git=git\n',
        )
        self.assertEqual(shell.result("startup-order"), b"env\nrc\n")
        _, generation = shell.submit('patina_startup_alias > "$_PROBE_DIR/result"')
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"configured")
        _, generation = shell.submit('print -rn -- "$PATH" > "$_PROBE_DIR/path"')
        shell.ready_after(generation)
        self.assertTrue(shell.result("path").startswith(f"{shell.root}/custom-bin:".encode()))
        self.assertEqual(shell.complete("patina_startup_a")["items"][0]["buffer"], "patina_startup_alias ")
        self.assertIn("patina_git checkout", {item["buffer"] for item in shell.complete("patina_git che")["items"]})

    def test_zshenv_can_redirect_later_startup_files(self):
        shell = self.shell(
            login=True,
            startup_files={
                ".zshenv": 'export ZDOTDIR="$HOME/config"\n',
                "config/.zprofile": 'export PROBE_REDIRECT_PROFILE=loaded\n',
                "config/.zshrc": 'typeset -g _PROBE_DIR=$HOME\n'
                'export PROBE_REDIRECT_RC=loaded\n',
                "config/.zlogin": 'export PROBE_REDIRECT_LOGIN=loaded\n',
            },
            user_rc='export PROBE_WRONG_RC=loaded\n',
        )
        _, generation = shell.submit(
            'print -rn -- "$ZDOTDIR|$PROBE_REDIRECT_PROFILE|$PROBE_REDIRECT_RC|'
            '$PROBE_REDIRECT_LOGIN|${+PROBE_WRONG_RC}" > "$HOME/result"'
        )
        shell.ready_after(generation)
        self.assertEqual(shell.result(), f"{shell.root}/config|loaded|loaded|loaded|0".encode())

    def test_preserves_unset_and_explicitly_empty_zdotdir(self):
        for mode, expected in (("unset", b"0|"), ("empty", b"1|")):
            with self.subTest(mode=mode):
                shell = self.shell(zdotdir=mode)
                _, generation = shell.submit(
                    'print -rn -- "${+ZDOTDIR}|${ZDOTDIR-}" > "$HOME/result"'
                )
                shell.ready_after(generation)
                self.assertEqual(shell.result(), expected)

    def test_existing_compsys_custom_fpath_styles_and_wrapper_survive(self):
        shell = self.shell(
            startup_files={
                "completions/_patina_configured": "#compdef patina_configured\n"
                "compadd -- 'configured one' 'configured two'\n",
                "PROFILE_FILE": "",
            },
            user_rc='fpath=("$HOME/completions" $fpath)\n'
            'autoload -Uz compinit\ncompinit -i -D\n'
            'autoload +X _main_complete\n'
            'functions[_probe_main_complete]=$functions[_main_complete]\n'
            '_main_complete() { print -rn -- used > "$HOME/completion-wrapper"; '
            '_probe_main_complete "$@"; }\n'
            'zstyle ":completion:*" matcher-list "m:{a-z}={A-Z}"\n'
            '_probe_custom() { compadd -- PROFILE_CHOICE; }\n'
            'compdef _probe_custom patina_upper\n',
        )
        self.assertEqual(
            {item["buffer"] for item in shell.complete("patina_configured ")["items"]},
            {"patina_configured configured\\ one", "patina_configured configured\\ two"},
        )
        self.assertEqual(shell.result("completion-wrapper"), b"used")
        self.assertEqual(shell.complete("patina_upper ")["items"][0]["buffer"], "patina_upper PROFILE_CHOICE ")
        self.assertEqual(shell.complete("cat pro")["items"][0]["buffer"], "cat PROFILE_FILE ")
        _, generation = shell.submit('print -rn -- "$fpath[1]" > "$HOME/result"')
        shell.ready_after(generation)
        self.assertEqual(shell.result(), f"{shell.root}/completions".encode())

    def test_fallback_compinit_discovers_user_fpath(self):
        shell = self.shell(
            startup_files={
                "completions/_patina_lazy": "#compdef patina_lazy\ncompadd -- lazy-choice\n",
            },
            user_rc='fpath=("$HOME/completions" $fpath)\n',
        )
        self.assertEqual(shell.complete("patina_lazy la")["items"][0]["buffer"], "patina_lazy lazy-choice ")

    def test_missing_hook_helper_keeps_ordinary_terminal_working(self):
        shell = self.shell(user_rc="fpath=()\n", native_ready=False)
        self.assertEqual(shell.state()[0], "missing")
        shell.raw('print -rn -- "$PS1|${#fpath[@]}" > "$HOME/result"\r')
        shell.wait(lambda: shell.result() is not None)
        self.assertEqual(shell.result(), b"probe> |0")
        self.assertNotIn(b"function definition file not found", shell.output)

    def test_completion_options_follow_initial_and_live_shell_configuration(self):
        shell = self.shell(user_rc='autoload -Uz compinit\ncompinit -i -D\n'
            '_probe_option_completion() { compadd -- "$options[completealiases]"; }\n'
            'compdef _probe_option_completion patina_option\n'
            '_probe_target_completion() { compadd -- target-choice; }\n'
            '_probe_alias_completion() { compadd -- alias-choice; }\n'
            'compdef _probe_target_completion patina_target\n'
            'compdef _probe_alias_completion patina_alias\n'
            'alias patina_alias=patina_target\n'
            'setopt complete_aliases\n')
        self.assertEqual(shell.complete("patina_option ")["items"][0]["buffer"], "patina_option on ")
        self.assertEqual(shell.complete("patina_alias ")["items"][0]["buffer"], "patina_alias alias-choice ")
        _, generation = shell.submit("unsetopt complete_aliases")
        shell.ready_after(generation)
        self.assertEqual(shell.complete("patina_option ")["items"][0]["buffer"], "patina_option off ")
        self.assertEqual(shell.complete("patina_alias ")["items"][0]["buffer"], "patina_alias target-choice ")

    def test_custom_main_keymap_and_zle_hooks_coexist(self):
        shell = self.shell(user_rc='bindkey -v\n'
            'bindkey -N patina-user-map viins\nbindkey -A patina-user-map main\n'
            '_probe_key() { BUFFER=\'print -rn -- keymap > "$HOME/result"\'; CURSOR=$#BUFFER; }\n'
            'zle -N _probe_key\nbindkey -M patina-user-map "^X" _probe_key\n'
            '_probe_init() { print -r -- init >> "$HOME/zle-hooks"; }\n'
            '_probe_redraw() { print -r -- redraw >> "$HOME/zle-hooks"; }\n'
            '_probe_finish_extra() { print -r -- finish >> "$HOME/zle-hooks"; }\n'
            'zle -N zle-line-init _probe_init\n'
            'autoload -Uz add-zle-hook-widget\n'
            'add-zle-hook-widget line-pre-redraw _probe_redraw\n'
            'add-zle-hook-widget line-finish _probe_finish_extra\n')
        self.assertTrue(shell.complete("prin")["items"])
        generation = shell.state()[1]
        shell.raw(b"\x18")
        shell.wait(lambda: shell.state()[0] == "terminal")
        shell.raw("\r")
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"keymap")
        hooks = shell.result("zle-hooks").splitlines()
        self.assertIn(b"redraw", hooks)
        self.assertEqual(hooks.count(b"finish"), 1)
        self.assertEqual(hooks.count(b"init"), 2)
        _, generation = shell.submit('bindkey -lL main > "$HOME/keymap"')
        shell.ready_after(generation)
        self.assertIn(b"patina-user-map main", shell.result("keymap"))

    def test_user_history_receives_native_commands(self):
        shell = self.shell(user_rc='HISTFILE="$HOME/configured-history"\n'
            'HISTSIZE=100\nSAVEHIST=100\nsetopt inc_append_history extended_history\n')
        draft = "export PATINA_HISTORY_PROBE=configured"
        _, generation = shell.submit(draft)
        shell.ready_after(generation)
        shell.wait(lambda: shell.result("configured-history") is not None)
        self.assertIn(draft.encode(), shell.result("configured-history"))
        _, generation = shell.submit('print -rn -- "$HISTFILE|$SAVEHIST|${options[incappendhistory]}" > "$HOME/result"')
        shell.ready_after(generation)
        self.assertEqual(shell.result(), f"{shell.root}/configured-history|100|on".encode())

    def test_aliases_and_nondefault_options_do_not_change_transport(self):
        shell = self.shell(user_rc='alias local="print BAD_LOCAL"\n'
            'alias typeset="print BAD_TYPESET"\n'
            'alias source="print BAD_SOURCE"\n'
            'alias _patina_native_submit="print BAD_WIDGET"\n'
            'setopt sh_word_split ksh_arrays no_unset warn_create_global complete_aliases\n')
        _, generation = shell.submit(
            'builtin print -rn -- "${options[shwordsplit]}|${options[ksharrays]}|'
            '${options[nounset]}|${options[warncreateglobal]}|${options[completealiases]}" '
            '> "$HOME/result"'
        )
        shell.ready_after(generation)
        self.assertEqual(shell.result(), b"on|on|on|on|on")
        self.assertTrue(shell.complete("prin")["items"])
        self.assertNotIn(b"BAD_", shell.output)

    def test_prompt_themes_keep_their_values_between_commands(self):
        shell = self.shell(user_rc='typeset -gi _probe_theme_count=0\n'
            '_probe_theme() { (( ++_probe_theme_count )); '
            'PS1="theme-$_probe_theme_count> "; PS2="secondary> "; RPS1="right"; return 0; }\n'
            'precmd_functions+=(_probe_theme)\n'
            '_probe_before_command() { print -rn -- "$PS1|$PS2|$RPS1" > "$HOME/prompt-values"; }\n'
            'preexec_functions+=(_probe_before_command)\n')
        _, generation = shell.submit("true")
        shell.ready_after(generation)
        self.assertEqual(shell.result("prompt-values"), b"theme-1> |secondary> |right")
        _, generation = shell.submit("true")
        shell.ready_after(generation)
        self.assertEqual(shell.result("prompt-values"), b"theme-2> |secondary> |right")
        self.assertTrue(shell.complete("prin")["items"])
        block = shell.state()[3]
        _, generation = shell.submit("false")
        shell.ready_after(generation)
        self.assertEqual(shell.metadata(block, "exit-status"), b"1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
