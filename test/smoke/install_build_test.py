"""Installer builds by default; failed builds preserve installed artifacts."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as tmp:
    fixture = Path(tmp) / "repo"
    fixture.mkdir()
    for name in ["install.sh", "build-rust-dispatcher.sh"]:
        shutil.copy2(root / name, fixture / name)
    for name in ["libexec", "skills/makevn"]:
        shutil.copytree(root / name, fixture / name)
    manifest = fixture / "rust/dispatcher/Cargo.toml"
    manifest.parent.mkdir(parents=True)
    manifest.write_text('[package]\nversion = "0.1.15"\n')
    fakebin = Path(tmp) / "fakebin"
    fakebin.mkdir()
    cargo = fakebin / "cargo"
    cargo.write_text('''#!/bin/bash
set -eu
printf 'build\n' >> "$CALLS"
[[ "${FAIL_BUILD:-0}" != 1 ]] || exit 42
output="$CARGO_TARGET_DIR/${MAKEVN_RUST_TARGET:+$MAKEVN_RUST_TARGET/}release"
mkdir -p "$output"
for name in makevn makevn-mcp; do
  printf '#!/bin/bash\nprintf "fresh binary\\\\n"\n' > "$output/$name"
  chmod +x "$output/$name"
done
''')
    cargo.chmod(0o755)
    prefix = Path(tmp) / "prefix"
    calls = Path(tmp) / "calls"
    env = {**os.environ, "PATH": str(fakebin) + os.pathsep + os.environ["PATH"], "PREFIX": str(prefix), "CALLS": str(calls)}
    env.pop("MAKEVN_RUST_TARGET", None)
    def run(*args, **overrides):
        return subprocess.run(["bash", str(fixture / "install.sh"), *args], env={**env, **overrides}, capture_output=True, text=True)
    assert run("--help").returncode == 0
    assert not prefix.exists() and not calls.exists()
    release = fixture / "target/release"
    release.mkdir(parents=True)
    for name in ["makevn", "makevn-mcp"]:
        (release / name).write_text("#!/bin/bash\necho stale\n")
        (release / name).chmod(0o755)
    result = run()
    assert result.returncode == 0, result.stderr
    assert calls.read_text().splitlines() == ["build"]
    assert "fresh binary" in (prefix / "bin/makevn").read_text()
    installed = (prefix / "bin/makevn").read_bytes()
    version = (fixture / "target/makevn-version.env").read_bytes()
    installed_version = (prefix / "libexec/makevn/version.env").read_bytes()
    assert run(FAIL_BUILD="1").returncode == 42
    assert (prefix / "bin/makevn").read_bytes() == installed
    assert (fixture / "target/makevn-version.env").read_bytes() == version
    assert (prefix / "libexec/makevn/version.env").read_bytes() == installed_version
    count = calls.read_text()
    assert run("--no-build", FAIL_BUILD="1").returncode == 0
    assert calls.read_text() == count
    assert run(MAKEVN_RUST_TARGET="fixture-target").returncode == 0
    assert "fresh binary" in (prefix / "bin/makevn").read_text()
    (fixture / "target/fixture-target/release/makevn-mcp").unlink()
    assert run("--no-build", MAKEVN_RUST_TARGET="fixture-target").returncode != 0
print("Installer build regression tests passed")
