"""Exercise one live tail block across backend metadata updates in a real PTY."""
import codecs
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


def backend(args):
    metadata = Path(args[args.index('--metadata-out') + 1])
    repo = Path(args[args.index('--repo') + 1])
    phases = ['karate-docker-up', 'package', 'run-app-bg', 'run-app-bg',
              'docker-ps-required', 'karate-test']
    for index, phase in enumerate(phases):
        log = repo / (phase + '.log')
        with log.open('a') as stream:
            stream.write(f'LOG_STAGE_{index}\n')
        values = dict(command=phase, repo=str(repo), cwd=str(repo),
                      log_path=str(log), relative_log_path=log.name,
                      command_display=f'{phase} revision {index}', title=phase,
                      context='code')
        pending = metadata.with_suffix('.pending')
        pending.write_text(''.join(f'{key}={value}\n' for key, value in values.items()))
        pending.replace(metadata)
        (repo / 'stage').write_text(str(index))
        deadline = time.monotonic() + 20
        while not (repo / f'ack-{index}').exists():
            if time.monotonic() > deadline:
                raise TimeoutError(f'No terminal acknowledgement for stage {index}')
            time.sleep(0.02)
        if index != 2:
            phase_index = [1, 2, 3, 3, 4, 5][index]
            code = int(os.environ.get('MAKEVN_TEST_PHASE_EXIT', '0')) if index == 5 else 0
            record = Path(os.environ['MAKEVN_BACKEND_PHASE_DIR']) / str(phase_index)
            record.write_text(pending_content(values) + f'duration_seconds=1\nexit_code={code}\n')
    sys.exit(int(os.environ.get('MAKEVN_TEST_PHASE_EXIT', '0')))


def pending_content(values):
    return ''.join(f'{key}={value}\n' for key, value in values.items())


class Screen:
    """Minimal CSI screen model for this renderer's cursor/erase sequences."""
    def __init__(self):
        self.row = self.column = 0
        self.rows = {}
        self.escape = None

    def feed(self, text):
        for char in text:
            if self.escape is not None:
                self.escape += char
                if self.escape == '\x1b[':
                    continue
                if len(self.escape) == 2 and char != '[':
                    self.escape = None
                elif len(self.escape) > 2 and '@' <= char <= '~':
                    self.csi(self.escape[2:-1], char)
                    self.escape = None
                continue
            if char == '\x1b':
                self.escape = char
            elif char == '\r':
                self.column = 0
            elif char == '\n':
                self.row += 1
            elif char == '\b':
                self.column = max(0, self.column - 1)
            elif char >= ' ':
                line = self.rows.setdefault(self.row, [])
                while len(line) <= self.column:
                    line.append(' ')
                line[self.column] = char
                self.column += 1

    def csi(self, parameters, command):
        number = int(parameters) if parameters.isdigit() else 1
        if command == 'A':
            self.row = max(0, self.row - number)
        elif command == 'B':
            self.row += number
        elif command == 'C':
            self.column += number
        elif command == 'D':
            self.column = max(0, self.column - number)
        elif command == 'G':
            self.column = max(0, number - 1)
        elif command == 'K':
            if parameters == '2':
                self.rows[self.row] = []
            else:
                self.rows[self.row] = self.rows.get(self.row, [])[:self.column]

    def lines(self):
        return [''.join(self.rows.get(row, [])) for row in range(max(self.rows, default=0) + 1)]


def verify(binary, exit_code=0, tail_enabled=True, hide_at_end=False):
    with tempfile.TemporaryDirectory(prefix='makevn-tail-metadata-') as folder:
        repo = Path(folder)
        backend_path = repo / 'libexec/makevn/backend.sh'
        backend_path.parent.mkdir(parents=True)
        backend_path.write_text('#!/usr/bin/env bash\nexec "' + sys.executable + '" "' +
                                str(Path(__file__).resolve()) + '" --backend "$@"\n')
        pid, fd = pty.fork()
        if pid == 0:
            os.environ['MAKEVN_INSTALL_ROOT'] = str(repo)
            os.environ['NO_COLOR'] = '1'
            os.environ['TERM'] = 'xterm-256color'
            os.environ.pop('MAKEVN_AGENT_OUTPUT', None)
            os.environ.pop('MAKEVN_COMPACT_OUTPUT', None)
            os.environ['MAKEVN_TEST_PHASE_EXIT'] = str(exit_code)
            os.execv(binary, [binary, '--repo', str(repo), 'karate-all'])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 80, 200, 0, 0))
        screen = Screen()
        decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
        transcript = bytearray()

        def pump():
            readable, _, _ = select.select([fd], [], [], 0.02)
            if readable:
                chunk = os.read(fd, 65536)
                if not chunk:
                    raise EOFError('PTY closed')
                transcript.extend(chunk)
                screen.feed(decoder.decode(chunk))

        def until(predicate):
            deadline = time.monotonic() + 15
            while not predicate():
                if time.monotonic() >= deadline:
                    raise AssertionError('\n'.join(screen.lines()))
                pump()

        def settle():
            deadline = time.monotonic() + 0.25
            while time.monotonic() < deadline:
                pump()

        try:
            until(lambda: any('makevn karate-docker-up' in line for line in screen.lines()))
            if tail_enabled:
                os.write(fd, b't')
                until(lambda: any('tailing log:' in line for line in screen.lines()))
                os.write(fd, b'++')
            settle()
            phases = ['karate-docker-up', 'package', 'run-app-bg', 'run-app-bg',
                      'docker-ps-required', 'karate-test']
            for index, phase in enumerate(phases):
                if tail_enabled and index == 3:
                    # Metadata changes while the tail is hidden.
                    until(lambda: (repo / 'stage').read_text() == str(index)
                          and any(f'makevn {phase}' in line for line in screen.lines()))
                    settle()
                    assert not any('tailing log:' in line or 'LOG_STAGE_' in line
                                   for line in screen.lines()), '\n'.join(screen.lines())
                    os.write(fd, b'T')
                def complete_phase():
                    lines = screen.lines()
                    if not tail_enabled:
                        return ((repo / 'stage').read_text() == str(index)
                                and any(f'makevn {phase}' in line for line in lines)
                                and (index == 0 or any('karate-docker-up |' in line for line in lines)))
                    notices = [row for row, line in enumerate(lines) if 'tailing log:' in line]
                    return (any(f'LOG_STAGE_{index}' in line for line in lines)
                            and any(f'makevn {phase}' in line for line in lines)
                            and len(notices) == 1
                            and screen.row - notices[0] == 7
                            and screen.column > 0)
                until(complete_phase)
                lines = screen.lines()
                assert sum('Working for ' in line for line in lines) == 1, '\n'.join(lines)
                assert sum(f'makevn {phase}' in line for line in lines) == 1, '\n'.join(lines)
                if tail_enabled:
                    assert sum('tailing log:' in line for line in lines) == 1, '\n'.join(lines)
                    notice_row = next(row for row, line in enumerate(lines) if 'tailing log:' in line)
                    assert screen.row - notice_row == 7, f'row={screen.row} notice={notice_row}\n' + '\n'.join(lines)
                    footers = [row for row, line in enumerate(lines) if 't hide tail' in line]
                    assert footers == [screen.row], '\n'.join(lines)
                    assert not any(line.strip() for line in lines[screen.row + 1:]), '\n'.join(lines)
                    if index > 0:
                        assert any('karate-docker-up |' in line and '1s' in line for line in lines), '\n'.join(lines)
                    if index == 3:
                        assert sum('LOG_STAGE_2' in line for line in lines) == 1, '\n'.join(lines)
                    if index and index != 3:
                        assert not any(f'LOG_STAGE_{index - 1}' in line for line in lines), '\n'.join(lines)
                if tail_enabled and index in (1, 2, 5):
                    os.write(fd, b't')
                    until(lambda: any('t tail' in line for line in screen.lines())
                          and not any('tailing log:' in line or 'LOG_STAGE_' in line
                                      for line in screen.lines()))
                    settle()
                    assert sum('Working for ' in line for line in screen.lines()) == 1
                    if index == 1 or (index == 5 and not hide_at_end):
                        os.write(fd, b't')
                        until(complete_phase)
                        # Resizing the tail still leaves the footer last.
                        os.write(fd, b'-')
                        until(lambda: screen.row - next(
                            (row for row, line in enumerate(screen.lines())
                             if 'tailing log:' in line), screen.row) == 6)
                        os.write(fd, b'+')
                        until(complete_phase)
                (repo / f'ack-{index}').touch()
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                try:
                    pump()
                except (OSError, EOFError):
                    break
            else:
                raise TimeoutError('Dispatcher did not finish')
            _, status = os.waitpid(pid, 0)
            assert os.waitstatus_to_exitcode(status) == exit_code
            final = screen.lines()
            for phase in dict.fromkeys(phases):
                assert any(f'{phase} |' in line and f'{phase}.log' in line for line in final), '\n'.join(final)
            assert not any('Working for ' in line or 'tailing log:' in line
                           or 't hide tail' in line or 'LOG_STAGE_' in line
                           for line in screen.lines()), '\n'.join(screen.lines())
        finally:
            os.close(fd)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if os.environ.get('MAKEVN_TAIL_PTY_TRANSCRIPT'):
                Path(os.environ['MAKEVN_TAIL_PTY_TRANSCRIPT']).write_bytes(transcript)


if __name__ == '__main__':
    if sys.argv[1] == '--backend':
        backend(sys.argv[2:])
    elif Path(sys.argv[1]).is_file():
        verify(str(Path(sys.argv[1]).resolve()))
        verify(str(Path(sys.argv[1]).resolve()), 42)
        verify(str(Path(sys.argv[1]).resolve()), 42, False)
        verify(str(Path(sys.argv[1]).resolve()), hide_at_end=True)
        subprocess.run([sys.executable, str(Path(__file__).with_name('dashboard_transition_pty_test.py')),
                        str(Path(sys.argv[1]).resolve())], check=True)
        print('Tail metadata PTY regression tests passed')
    else:
        print('Tail metadata PTY test skipped: Rust dispatcher not built')
