#!/usr/bin/env python3
"""PTY integration tests for the opt-in, isolated native-input zsh prototype.

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
import tempfile
import time
import unittest
import uuid
from pathlib import Path


ADAPTER = (
    Path(__file__).resolve().parents[2]
    / "macos/Sources/Features/Command Input/native-input.zsh"
)
TRIGGER = b"\x1b[99;1~"
COMPLETION_TRIGGER = b"\x1b[99;2~"


class Shell:
    def __init__(self):
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
            f"source {shlex.quote(str(ADAPTER))}\n"
            "_probe_finish() {\n"
            '  builtin print -rn -- "$BUFFER" > "$_PROBE_DIR/last-buffer"\n'
            "  _patina_native_line_finish\n}\n"
            "zle -N zle-line-finish _probe_finish\n"
        )
        self.pid, self.terminal = pty.fork()
        if self.pid == 0:
            os.chdir(self.root)
            os.execve(
                "/bin/zsh", ["zsh", "--no-globalrcs", "-i"],
                {
                    "HOME": str(self.root), "ZDOTDIR": str(self.root),
                    "PATINA_NATIVE_INPUT_DIR": str(self.bridge),
                    "TERM": "xterm-256color", "PATH": "/usr/bin:/bin",
                    "LC_ALL": "en_US.UTF-8",
                },
            )
        os.set_blocking(self.terminal, False)
        self.output = bytearray()
        try:
            self.wait(lambda: self.state()[0] == "ready")
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

    def test_primary_block_reserves_one_header_row_and_finishes_in_order(self):
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
        self.assertIn(f"\x1b]133;A;aid={block}\x07\r\n".encode(), shell.output)
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
