# README demos

These VHS recordings execute real CLI/MCP commands. Operational demos use a
matched source-built `makevn` / `makevn-mcp` pair; installation demos show the
published release, which may have a different build timestamp.

## Requirements and isolated runtime

Install VHS, ffmpeg/ffprobe and ttyd, plus Rust, Java and Maven. Run from the
repository root:

```bash
export MAKEVN_DEMO_ROOT="$PWD"
export MAKEVN_DEMO_PREFIX="$(bash docs/demo/prepare-runtime.sh)"
python3 -m unittest discover -s test/smoke -p demo_mcp_test.py
vhs validate docs/demo/*.tape
```

Preparation installs the complete runtime into a unique temporary prefix, never
into the personal installation. Keep this same prefix for every operational
recording. Fixtures pin compiler/Surefire plugins and produce genuine JUnit and
JaCoCo results. Only telemetry depends on the sibling `../cathode` checkout;
it clones that checkout and never executes mutable commands in the original.

## Validate, record, inspect

Before recording, execute the intended workflow to completion on a temporary
fixture, starting with `makevn doctor --compact` and initializing only when
recommended. Use `setup-demo-repo.sh developer <temporary-path>` for ordinary
flows or `agent` mode for covered working-tree changes. Prepend
`$MAKEVN_DEMO_PREFIX/bin` to PATH. Changed-code validation is:

```bash
makevn doctor --compact
makevn init # for the fresh supported fixture
makevn verify-changes-preview
makevn verify-changes
makevn coverage-changes
```

Then record:

```bash
for demo in developer changes mcp tail telemetry; do
  python3 docs/demo/record.py "$demo"
done
python3 docs/demo/record.py install-asdf
```

`record.py` gives VHS a PTY and a fresh temporary output. It rejects a missing,
empty or invalid GIF before replacing the previous asset. This matters because
VHS may exit successfully without producing an output. In this environment VHS
0.12.0 did exactly that; recordings were generated with a checksum-verified,
temporary VHS 0.10.0. Use `--vhs /path/to/vhs` to select an alternate binary
without replacing the personal installation.

The session helper removes inherited `NO_COLOR`, `MAKEVN_AGENT_OUTPUT` and
`MAKEVN_COMPACT_OUTPUT`, and sets `TERM=xterm-256color` / `COLORTERM=truecolor`.
This restores the real human-facing CLI colors even when VHS is launched by an
agent with monochrome output enabled. The VHS theme only defines the palette;
it cannot color output that lacks ANSI styles. MCP subprocesses still explicitly
use their compact, colorless agent output; their behavior is unchanged.

Tapes wait for the final Bash prompt, with a 15-minute limit, instead of guessing
Maven durations. The sourced session helper exits immediately after a failed command, causing
VHS to reject the recording rather than return a success prompt. Still inspect
results and managed logs, then sample intermediate and final GIF frames for
legibility, clipping, errors, prompts and secrets before publishing.

## MCP and agents

`mcp.tape` uses `mcp_demo.py` to initialize the real stdio MCP connection,
wait for the initialization response, send `notifications/initialized`, and
call `doctor`, `init`, then `composite_run` (`clean`, `compile`, `package`).
It displays real arguments and the complete structured envelope; arrays are
formatted compactly for readability, without changing values. Trace is omitted.
Transport errors, tool failures, missing responses and timeouts return nonzero.

Agent tapes use the same generated fixture and temporary project configuration.
`agent_demo.py` preserves the client's configured model and verifies completed
makevn MCP `doctor` and `composite_run` events, rejecting CLI-only runs. Codex
uses an ephemeral session and an explicit per-process MCP command override;
OpenCode reads the project-local `opencode.json`. Neither changes personal
configuration or copies credentials. Run the helper successfully before recording.
Both clients need valid authentication; Codex also needs Node on PATH.

```bash
python3 docs/demo/record.py agent
python3 docs/demo/record.py opencode
```

## Optional Docker and installation recordings

Docker requires a running daemon. The fixture explicitly declares boot-container
requirements; the tape initializes after doctor, waits up to 30 seconds for the
required service, verifies, and finishes with `makevn docker-down`. If a recording
is interrupted, run that cleanup command in its temporary fixture yourself.
Docker lifecycle operations can remove volumes; use a disposable Docker context.

Homebrew installation must run in a disposable environment where the formula is
not already installed. Never uninstall the user's installation to stage a demo.
The asdf tape isolates `ASDF_DATA_DIR` and uses project-local `asdf set`, not `-u`.

```bash
MAKEVN_DEMO_DISPOSABLE=1 python3 docs/demo/record.py verify-docker
# Disposable Homebrew environment only:
MAKEVN_DEMO_DISPOSABLE=1 python3 docs/demo/record.py install-brew
```

## Recording status — 2026-10-09

| Demo | Status |
| --- | --- |
| Developer | Refreshed in color from this branch; targeted test and verify passed |
| Changed-code coverage | New, in color; all three coverage gates passed at 100% |
| Direct MCP | New; real structured results and three successful workflow steps |
| Tail | Refreshed in color using the self-contained fixture |
| Telemetry | Refreshed in color against a temporary cathode clone |
| asdf installation | Refreshed; published v0.1.15, isolated project selection |
| Codex | Pending: configured model rejected by CLI account; previous GIF retained |
| OpenCode | Pending: token refresh returned 401; previous GIF retained |
| Docker verification | Pending: no running Docker daemon; previous GIF retained |
| Homebrew installation | Pending: no disposable Homebrew environment; previous GIF retained |

Pending GIFs are linked as historical recordings in the main README, not embedded
as examples of current output. Do not mark them refreshed until the prerequisite
is resolved and a real successful run has been inspected.

## Validation results

- Nine demo-client tests pass, including real subprocess transport failure cases
  and color-environment regression coverage (including empty `NO_COLOR`).
- All ten VHS tapes parse successfully.
- Rust tests: 314 passed outside the filesystem sandbox. Inside it, a process
  sampling test was denied permission; this was not a product failure.
- Sanitization passes on a clean snapshot of the staged source. Direct local
  sanitization encounters an existing ignored `.makevn/state.json` containing
  a machine-local path. Leave that unrelated state untouched; CI's clean checkout
  is authoritative for sanitization and the mandatory CRAP ratchet.
