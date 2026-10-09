"""Record into a fresh file, reject missing/invalid output, then replace the GIF."""
import argparse
import json
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import os


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("demo", choices=["developer", "changes", "mcp", "tail", "telemetry",
                                         "agent", "opencode", "verify-docker", "install-brew", "install-asdf"])
    parser.add_argument("--vhs", default="vhs")
    args = parser.parse_args()
    if args.demo in {"install-brew", "verify-docker"} and os.environ.get("MAKEVN_DEMO_DISPOSABLE") != "1":
        parser.error("use a disposable Homebrew/Docker environment and set MAKEVN_DEMO_DISPOSABLE=1")
    root = Path(__file__).resolve().parents[2]
    os.chdir(root)
    os.environ["MAKEVN_DEMO_ROOT"] = str(root)
    if not args.demo.startswith("install-"):
        prefix = os.environ.get("MAKEVN_DEMO_PREFIX")
        if not prefix or not all((Path(prefix) / "bin" / binary).is_file() for binary in ["makevn", "makevn-mcp"]):
            parser.error("set MAKEVN_DEMO_PREFIX to the isolated prepared runtime")
    with tempfile.TemporaryDirectory(prefix="makevn-vhs-") as tmp:
        gif = Path(tmp) / "recording.gif"
        status = pty.spawn([args.vhs, str(root / "docs/demo" / (args.demo + ".tape")), "-o", str(gif)])
        if os.waitstatus_to_exitcode(status) != 0:
            raise SystemExit("VHS failed; existing GIF preserved")
        if not gif.is_file() or gif.stat().st_size == 0:
            raise SystemExit("VHS produced no new GIF; existing GIF preserved")
        probe = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(gif)],
                               check=True, capture_output=True, text=True)
        info = json.loads(probe.stdout)
        if float(info["format"]["duration"]) <= 0 or not info["streams"]:
            raise SystemExit("Invalid recording; existing GIF preserved")
        destination = root / "docs/assets" / ("makevn-" + args.demo + ".gif")
        shutil.copyfile(gif, destination)
        print("Recorded:", destination)
        print("Inspect representative frames and confirm real workflow success before publishing.")


if __name__ == "__main__":
    main()
