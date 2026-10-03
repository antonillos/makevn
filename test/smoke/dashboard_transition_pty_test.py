"""Keep the previous live dashboard visible while the next command starts."""
import codecs
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import sys
import tempfile
import termios
import time

from tail_metadata_pty_test import Screen


def backend(args):
    repo = Path(args[args.index('--repo') + 1])
    title = args[0]
    if title == 'docker-ps-required':
        (repo / 'waiting').touch()
        deadline = time.monotonic() + 10
        while not (repo / 'continue').exists():
            assert time.monotonic() < deadline
            time.sleep(0.02)
    metadata = Path(args[args.index('--metadata-out') + 1])
    metadata.write_text(f'command={title}\nrepo={repo}\ncwd={repo}\n'
                        f'log_path={repo / "log"}\nrelative_log_path=log\n'
                        f'command_display=makevn {title}\ntitle={title}\n')
    Path(os.environ['MAKEVN_BACKEND_DETAIL_OUT']).write_text('PRESERVED_DETAIL\n')
    time.sleep(0.4)


def verify(binary):
    with tempfile.TemporaryDirectory() as folder:
        repo = Path(folder)
        script = repo / 'libexec/makevn/backend.sh'
        script.parent.mkdir(parents=True)
        script.write_text(f'#!/bin/bash\nexec "{sys.executable}" "{Path(__file__).resolve()}" --backend "$@"\n')
        pid, fd = pty.fork()
        if pid == 0:
            os.environ.update(MAKEVN_INSTALL_ROOT=str(repo), NO_COLOR='1', TERM='xterm')
            os.environ.pop('MAKEVN_AGENT_OUTPUT', None)
            os.environ.pop('MAKEVN_COMPACT_OUTPUT', None)
            os.execv(binary, [binary, '--repo', str(repo), 'docker-up', 'docker-ps-required'])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 80, 200, 0, 0))
        screen = Screen()
        decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
        deadline = time.monotonic() + 15
        checked = False
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.05)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    screen.feed(decoder.decode(chunk))
                if (repo / 'waiting').exists() and not checked:
                    # Let the pending-command loader render repeatedly without metadata.
                    time.sleep(0.3)
                    while select.select([fd], [], [], 0)[0]:
                        screen.feed(decoder.decode(os.read(fd, 65536)))
                    lines = '\n'.join(screen.lines())
                    assert 'Working for' in lines, lines
                    assert 'PRESERVED_DETAIL' in lines, lines
                    assert 'makevn docker-up' in lines, lines
                    checked = True
                    (repo / 'continue').touch()
            assert checked
            _, status = os.waitpid(pid, 0)
            assert os.waitstatus_to_exitcode(status) == 0
            assert 'Worked  for' in '\n'.join(screen.lines())
        finally:
            os.close(fd)


if __name__ == '__main__':
    if sys.argv[1] == '--backend':
        backend(sys.argv[2:])
    else:
        verify(str(Path(sys.argv[1]).resolve()))
        print('dashboard transition PTY: ok')
