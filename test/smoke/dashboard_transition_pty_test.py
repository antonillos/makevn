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
    (repo / 'log').write_text(f'{title} log output\n')
    Path(os.environ['MAKEVN_BACKEND_DETAIL_OUT']).write_text('PRESERVED_DETAIL\n')
    time.sleep(0.4)


def verify(binary, tail_enabled=False, color_enabled=False):
    with tempfile.TemporaryDirectory() as folder:
        repo = Path(folder)
        script = repo / 'libexec/makevn/backend.sh'
        script.parent.mkdir(parents=True)
        script.write_text(f'#!/bin/bash\nexec "{sys.executable}" "{Path(__file__).resolve()}" --backend "$@"\n')
        pid, fd = pty.fork()
        if pid == 0:
            # This synthetic backend contains no product Bash to cover. Inherited
            # bashcov tracing writes diagnostics into stderr and legitimately
            # takes ownership of the dashboard, invalidating this no-output test.
            for name in ('BASH_ENV', 'BASH_XTRACEFD', 'SHELLOPTS', 'PS4'):
                os.environ.pop(name, None)
            os.environ.update(MAKEVN_INSTALL_ROOT=str(repo), NO_COLOR='1', TERM='xterm')
            if color_enabled:
                os.environ.pop('NO_COLOR', None)
            os.environ.pop('MAKEVN_AGENT_OUTPUT', None)
            os.environ.pop('MAKEVN_COMPACT_OUTPUT', None)
            args = [binary, '--repo', str(repo), 'docker-up', 'docker-ps-required']
            if tail_enabled:
                args.append('--tail')
            os.execv(binary, args)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 80, 200, 0, 0))
        screen = Screen()
        decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
        deadline = time.monotonic() + 15
        checked = False
        output = ''
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.05)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    decoded = decoder.decode(chunk)
                    output += decoded
                    screen.feed(decoded)
                if (repo / 'waiting').exists() and not checked:
                    # Let the pending-command loader render repeatedly without metadata.
                    time.sleep(0.3)
                    while select.select([fd], [], [], 0)[0]:
                        decoded = decoder.decode(os.read(fd, 65536))
                        output += decoded
                        screen.feed(decoded)
                    lines = '\n'.join(screen.lines())
                    assert 'Working for' in lines, lines
                    assert 'PRESERVED_DETAIL' in lines, lines
                    assert '[✓] docker-up' in lines, lines
                    assert '[•] makevn docker-ps-required (starting)' in lines, lines
                    assert 'makevn docker-up' not in lines, lines
                    assert 't tail' not in lines, lines
                    checked = True
                    (repo / 'continue').touch()
            assert checked
            _, status = os.waitpid(pid, 0)
            assert os.waitstatus_to_exitcode(status) == 0
            assert 'Worked  for' in '\n'.join(screen.lines())
            if color_enabled:
                for title in ('docker-up', 'docker-ps-required (starting)', 'docker-ps-required'):
                    assert f'\x1b[33mmakevn {title}\x1b[0m' in output, output
                    assert f'\x1b[36mmakevn {title}\x1b[0m' not in output, output
                assert '[\x1b[36m✓\x1b[0m]\x1b[90m docker-up |' in output, output
                assert '[\x1b[32mok\x1b[0m]' in output, output
            else:
                assert '\x1b[33m' not in output, output
        finally:
            os.close(fd)


if __name__ == '__main__':
    if sys.argv[1] == '--backend':
        backend(sys.argv[2:])
    else:
        verify(str(Path(sys.argv[1]).resolve()))
        verify(str(Path(sys.argv[1]).resolve()), True)
        verify(str(Path(sys.argv[1]).resolve()), color_enabled=True)
        verify(str(Path(sys.argv[1]).resolve()), True, color_enabled=True)
        print('dashboard transition PTY: ok')
