#!/usr/bin/env python3
"""PTY integration tests for the opt-in, isolated native-input zsh prototype.

Run: uv run --no-project --python python3 test/native-input/test_zsh_bridge.py
No Ghostty build or user startup files are required. Each test has a private
temporary HOME/ZDOTDIR, terminal, and bridge directory; no user history is read.
"""

import os
import pty
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


@unittest.skipUnless(Path("/bin/zsh").exists(), "requires /bin/zsh")
class NativeInputBridgeTests(unittest.TestCase):
    def setUp(self):
        self.shell = Shell()
        self.addCleanup(self.shell.close)

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
        _, generation = shell.submit("if true; then")
        shell.wait(lambda: shell.state()[0] == "terminal" and shell.state()[2] == "cont")
        self.assertNotEqual(shell.state()[1], generation)
        self.assertEqual(shell.receipt()[0], "accepted")
        shell.submit('print -r -- WRONG > "$_PROBE_DIR/result"')
        self.assertEqual(shell.receipt()[2], "not-primary-prompt")
        shell.raw('print -rn -- continued > "$_PROBE_DIR/result"\rfi\r')
        shell.wait(lambda: shell.result() == b"continued")
        shell.wait(lambda: shell.state()[0] == "ready")

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
