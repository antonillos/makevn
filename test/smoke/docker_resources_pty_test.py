"""Project-container metrics are asynchronous and visibly scoped in the live UI."""
import errno
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import sys
import tempfile
import termios
import time


def verify(binary):
    with tempfile.TemporaryDirectory(prefix='makevn-docker-resources-') as directory:
        root = Path(directory)
        backend = root / 'libexec/makevn/backend.sh'
        backend.parent.mkdir(parents=True)
        backend.write_text('''#!/bin/bash
repo=""; metadata=""
while (( $# )); do
 case "$1" in --repo) repo="$2"; shift 2;; --metadata-out) metadata="$2"; shift 2;; *) shift;; esac
done
printf 'command=docker-up\\nrepo=%s\\ncwd=%s\\nlog_path=%s/log\\nrelative_log_path=log\\ncommand_display=docker-up\\ntitle=docker-up\\n' "$repo" "$repo" "$repo" > "$metadata"
printf '%s\\ndocker\\ncompose\\n-f\\ncustom.yml\\n' "$repo" > "$MAKEVN_FRONTEND_RESOURCE_SCOPE_OUT"
sleep 7
''')
        docker = root / 'docker'
        docker.write_text('''#!/bin/sh
if [ "$1" = compose ]; then
 printf '0123456789ab\\n'
else
 case "$*" in *0123456789ab*) ;; *) exit 9;; esac
 [ ! -f "$0.sampled" ] || exit 1
 touch "$0.sampled"
 sleep 1
 printf '%s\\n' '{"CPUPerc":"12.5%","MemUsage":"4MiB / 8GiB"}'
fi
''')
        docker.chmod(0o755)
        pid, fd = pty.fork()
        if pid == 0:
            for name in ('BASH_ENV', 'BASH_XTRACEFD', 'SHELLOPTS', 'PS4', 'MAKEVN_AGENT_OUTPUT', 'MAKEVN_COMPACT_OUTPUT'):
                os.environ.pop(name, None)
            os.environ.update(MAKEVN_INSTALL_ROOT=str(root), NO_COLOR='1', TERM='xterm',
                              PATH=str(root) + ':' + os.environ.get('PATH', ''))
            os.execv(binary, [binary, '--repo', str(root), 'docker-up'])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 80, 200, 0, 0))
        transcript = bytearray()
        deadline = time.monotonic() + 15
        status = None
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        break
                    if not chunk:
                        break
                    transcript.extend(chunk)
            else:
                raise AssertionError('Docker telemetry PTY timed out')
            _, status = os.waitpid(pid, 0)
            text = transcript.decode(errors='replace')
            assert os.waitstatus_to_exitcode(status) == 0, text
            assert 'ctr cpu            — | ram             —' in text, text
            assert 'ctr cpu' in text and '13%' in text and '4 MiB' in text, text
            # Missing data retains the graph, but time keeps moving it left.
            missing_graphs = re.findall(r'ctr cpu [^\r\n]*— \| ram ([ ▇]{6})  +—', text)
            assert len({graph for graph in missing_graphs if '▇' in graph}) >= 2, text
            # The slow stats subprocess must not pause loader animation.
            assert text.count('ctr cpu            — | ram             —') > 3, text
        finally:
            if status is None:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(fd)


if __name__ == '__main__':
    verify(str(Path(sys.argv[1]).resolve()))
    print('Docker resource telemetry PTY tests passed')
