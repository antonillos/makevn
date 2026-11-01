#!/usr/bin/env bash

extract_exit_code() {
  python3 - "$1" <<'PY'
import json
import re
import sys

output = sys.argv[1]
for line in reversed(output.splitlines()):
    try:
        metadata = json.loads(line)
    except ValueError:
        continue
    if isinstance(metadata, dict) and 'exitCode' in metadata:
        code = metadata['exitCode']
        if type(code) is not int:
            raise SystemExit(1)
        print(code)
        raise SystemExit(0)
legacy = re.search(r'exit\s+code\s+(-?\d+)\s*$', output)
if legacy:
    print(legacy[1])
else:
    raise SystemExit(1)
PY
}
