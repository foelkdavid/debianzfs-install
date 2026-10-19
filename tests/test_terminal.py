#!/usr/bin/env python3
"""Host-safe terminal-emulator regressions; requires the pyte Python package."""
import codecs
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

import pyte

REPO = Path(__file__).resolve().parents[1]


class TerminalTests(unittest.TestCase):
    def screen(self, body, resize=False, expected=0):
        with tempfile.TemporaryDirectory(prefix='debianzfs-terminal-') as temp:
            root = Path(temp)
            master, slave = pty.openpty()
            original_mode = termios.tcgetattr(slave)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            env = dict(os.environ, REPO=str(REPO), TEST_ROOT=temp, TERM='linux',
                       UI_DEVICE=os.ttyname(slave))
            env.pop('NO_COLOR', None)
            code = '''source "$REPO/install.sh"
BOOT_MODE=UEFI LOG_DIR="$TEST_ROOT/logs"
ui_init
cleanup_target() { :; }
trap 'installer_exit "$?"' EXIT
trap 'exit "$?"' ERR
trap 'exit 130' INT
''' + body + '''
touch "$TEST_ROOT/ready"
while [[ ! -e $TEST_ROOT/release ]]; do sleep .02; done
'''
            proc = subprocess.Popen(['bash', '-c', code], stdin=slave, stdout=slave,
                                    stderr=slave, env=env, start_new_session=True)
            screen = pyte.Screen(80, 24)
            stream = pyte.Stream(screen)
            decoder = codecs.getincrementaldecoder('utf-8')()
            output = ''
            resized = False
            try:
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    if resize and not resized and (root / 'resize').exists():
                        screen.resize(lines=12, columns=50)
                        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 12, 50, 0, 0))
                        os.killpg(proc.pid, signal.SIGWINCH)
                        (root / 'resized').touch()
                        resized = True
                    if select.select([master], [], [], .05)[0]:
                        chunk = decoder.decode(os.read(master, 65536))
                        output += chunk
                        stream.feed(chunk)
                    elif (root / 'ready').exists():
                        break
                    elif proc.poll() is not None:
                        if expected: break
                        self.fail(f'Fixture exited {proc.returncode}: {output}')
                else:
                    self.fail(f'Fixture timed out: {output}')
                if resize: self.assertTrue(resized)
                result = list(screen.display)
                (root / 'release').touch()
                self.assertEqual(proc.wait(timeout=4), expected, output)
                self.assertEqual(termios.tcgetattr(slave), original_mode)
                return result
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=4)
                os.close(master)
                os.close(slave)

    def assert_clean_stage(self, lines, expected):
        text = '\n'.join(lines)
        self.assertEqual(text.count('Debian-ZFS-Installer'), 1, text)
        self.assertEqual(text.count('Log:'), 1, text)
        self.assertEqual(lines[4].strip(), '', text)
        self.assertEqual(lines[5].strip(), '[short]', text)
        self.assertEqual(lines[6].strip(), '', text)
        self.assertEqual([line.rstrip() for line in lines[7:7 + len(expected)]], expected, text)
        self.assertTrue(all(not line.strip() for line in lines[7 + len(expected):]), text)
        self.assertNotIn('Archive mirror', text)
        self.assertNotIn('old-output', text)
        self.assertNotIn('previous long heading', text)

    def test_configuration_and_long_stage_are_erased_before_short_stage(self):
        lines = self.screen('''
reset_configuration
print_preconf_header
long_output() { for ((i=0;i<5;i++)); do echo "old-output-$i with a long trailing suffix"; done; }
short_output() { printf 'a\\nb\\nc\\nd\\ne\\n'; }
run_stage 'previous long heading that must disappear' long_output
run_stage short short_output
''')
        self.assert_clean_stage(lines, ['a', 'b', 'c', 'd', 'e'])

    def test_stage_does_not_depend_on_terminal_newline_processing(self):
        for flags in ('-onlcr', '-opost'):
            with self.subTest(flags=flags):
                lines = self.screen('''
change_mode() {
    stty -F "$UI_DEVICE" ''' + flags + '''
    printf 'a\\nb\\nc\\nd\\ne\\n'
    sleep .4
    touch "$TEST_ROOT/ready"
    while [[ ! -e $TEST_ROOT/release ]]; do sleep .02; done
}
run_stage short change_mode
''')
                self.assert_clean_stage(lines, ['a', 'b', 'c', 'd', 'e'])

    def test_resize_clears_reflowed_headers_and_output(self):
        lines = self.screen('''
resize_output() {
    for ((i=0;i<5;i++)); do printf 'old-output-%s and a very long suffix that used to wrap\\n' "$i"; done
    touch "$TEST_ROOT/resize"
    while [[ ! -e $TEST_ROOT/resized ]]; do sleep .01; done
    sleep .3
}
short_output() { printf 'a\\nb\\nc\\nd\\ne\\n'; }
run_stage 'previous long heading' resize_output
run_stage short short_output
''', resize=True)
        self.assert_clean_stage(lines, ['b', 'c', 'd', 'e'])

    def test_stage_commands_have_no_terminal_on_stdin(self):
        lines = self.screen('''
short_output() { [[ ! -t 0 && ! -t 1 && ! -t 2 ]]; printf 'a\\nb\\nc\\nd\\ne\\n'; }
run_stage short short_output
''')
        self.assert_clean_stage(lines, ['a', 'b', 'c', 'd', 'e'])

    def test_shorter_output_erases_trailing_text_within_one_stage(self):
        lines = self.screen('''
changing_output() {
    for ((i=0;i<5;i++)); do echo "old-output-$i with a long trailing suffix"; done
    sleep .4
    printf 'a\\nb\\nc\\nd\\ne\\n'
    sleep .4
}
run_stage short changing_output
''')
        self.assert_clean_stage(lines, ['a', 'b', 'c', 'd', 'e'])

    def test_interrupt_during_first_redraw_does_not_block_the_logger(self):
        lines = self.screen('''
render_stage() { kill -INT "$$"; }
run_stage short echo SHOULD-NOT-RUN
''', expected=130)
        text = '\n'.join(lines)
        self.assertIn('short (exit 130)', text)
        self.assertNotIn('SHOULD-NOT-RUN', text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
