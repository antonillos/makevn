"""Observe a normal Maven execution without rerunning or changing its result."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

import progressive_impact as progressive


def run(repo, base, java, arguments):
    properties = dict(flag[2:].split('=', 1) for flag in arguments if flag.startswith('-D') and '=' in flag)
    if properties.get('skipTests') == 'true' or properties.get('maven.test.skip') == 'true':
        return subprocess.call(arguments)
    try:
        before = progressive.initialize(repo, base, java)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, ET.ParseError):
        return subprocess.call(arguments)
    with tempfile.TemporaryDirectory(prefix='makevn-impact-observe-') as folder:
        traces = Path(folder)
        stamp = traces / 'stamp'
        stamp.touch()
        environment = dict(os.environ)
        environment['JAVA_TOOL_OPTIONS'] = environment.get('JAVA_TOOL_OPTIONS', '') + (
            ' "-Xlog:class+load=info:file=' + str(traces) + '/%p.log"')
        child = subprocess.Popen(arguments, env=environment)
        def forward(received, frame):
            try:
                child.send_signal(received)
            except ProcessLookupError:
                pass

        previous = {}
        for number in [signal.SIGINT, signal.SIGTERM]:
            previous[number] = signal.signal(number, forward)
        try:
            result = child.wait()
        finally:
            for number, handler in previous.items():
                signal.signal(number, handler)
        if result == 0:
            try:
                progressive.enrich(repo, base, java, before, stamp, traces)
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, ET.ParseError) as error:
                print('Test impact observation discarded: ' + str(error), file=sys.stderr)
        return result if result >= 0 else 128 - result


if __name__ == '__main__':
    repo, base, java, *arguments = sys.argv[1:]
    sys.exit(run(Path(repo).resolve(), Path(base).resolve(), Path(java), arguments))
