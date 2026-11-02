"""Keep completed impact-capture phases visible while the next class runs."""
import codecs
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import sys
import tempfile
import termios
import time

from tail_metadata_pty_test import Screen


def backend(args):
    metadata = Path(args[args.index('--metadata-out') + 1])
    repo = Path(args[args.index('--repo') + 1])
    for index, title in enumerate(['prepare dependencies (no tests)', 'verify . (example.OwnerTest)'], 1):
        log = repo / f'verify-changes-{index}.log'
        log.write_text('fixture output\n')
        content = (f'command=verify-changes\nrepo={repo}\ncwd={repo}\n'
                   f'log_path={log}\nrelative_log_path={log.name}\ncommand_display=fixture\ntitle={title}\n')
        pending = metadata.with_suffix('.pending')
        pending.write_text(content)
        pending.replace(metadata)
        deadline = time.monotonic() + 15
        while not (repo / f'ack-{index}').exists():
            if time.monotonic() > deadline:
                raise TimeoutError(f'No acknowledgement for phase {index}')
            time.sleep(0.02)
        record = Path(os.environ['MAKEVN_BACKEND_PHASE_DIR']) / str(index)
        record.write_text(content + 'duration_seconds=1\nexit_code=0\n')


def verify(binary):
    with tempfile.TemporaryDirectory(prefix='makevn-impact-progress-') as folder:
        repo = Path(folder)
        script = repo / 'libexec/makevn/backend.sh'
        script.parent.mkdir(parents=True)
        script.write_text(f'#!/bin/bash\nexec "{sys.executable}" "{Path(__file__).resolve()}" --backend "$@"\n')
        pid, fd = pty.fork()
        if pid == 0:
            os.environ.update(MAKEVN_INSTALL_ROOT=str(repo), NO_COLOR='1', TERM='xterm-256color')
            os.environ.pop('MAKEVN_AGENT_OUTPUT', None)
            os.environ.pop('MAKEVN_COMPACT_OUTPUT', None)
            os.execv(binary, [binary, '--repo', str(repo), 'test-impact-init'])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 200, 0, 0))
        screen = Screen()
        decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')

        def until(predicate):
            deadline = time.monotonic() + 15
            while not predicate(screen.lines()):
                if time.monotonic() > deadline:
                    raise AssertionError('\n'.join(screen.lines()))
                if select.select([fd], [], [], 0.05)[0]:
                    screen.feed(decoder.decode(os.read(fd, 65536)))

        try:
            until(lambda lines: any('prepare dependencies' in line for line in lines))
            (repo / 'ack-1').touch()
            until(lambda lines: any('example.OwnerTest' in line for line in lines))
            lines = screen.lines()
            assert any('prepare dependencies' in line and 'verify-changes-1.log' in line
                       for line in lines), '\n'.join(lines)
            assert any('[•] makevn test-impact-init' in line for line in lines)
            os.write(fd, b't')
            until(lambda lines: any('│    └ tailing log: verify-changes-2.log' in line for line in lines))
            (repo / 'ack-2').touch()
            until(lambda lines: any('[ok]' in line for line in lines))
            assert any('[✓] test-impact-init' in line for line in screen.lines())
            assert any('prepare dependencies' in line for line in screen.lines())
            assert any('example.OwnerTest' in line for line in screen.lines())
            _, status = os.waitpid(pid, 0)
            assert os.waitstatus_to_exitcode(status) == 0
        finally:
            os.close(fd)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


if __name__ == '__main__':
    if sys.argv[1] == '--backend':
        backend(sys.argv[2:])
    else:
        verify(str(Path(sys.argv[1]).resolve()))
        print('Test impact progress PTY regression passed')
