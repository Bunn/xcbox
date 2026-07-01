# xcbox

Run a coding agent on an Xcode/Swift project in a sandbox scoped to that project.
The agent sees **only your repo** (a Linux container with the repo bind-mounted); it
builds, tests, and runs the app **on the host** via
[XcodeBuildMCP](https://github.com/cameroncooke/XcodeBuildMCP), and commits/pushes with
**your git identity** — your SSH keys never enter the container.

Works for anything Xcode builds: **macOS, iOS, watchOS, tvOS, visionOS, and Swift packages.**

```bash
cd ~/YourApp
/path/to/xcbox/bin/xcbox        # brings up the sandbox and drops you in
#   inside:  claude → /login → "build, test, and commit this app"
```

## How it works

```
HOST (macOS)                              CONTAINER (Linux, repo-only)
  XcodeBuildMCP behind a stateful           your agent (e.g. claude)
  HTTP gateway on :8765  ◄─────────────────  connects over 192.168.64.1:8765
  Xcode toolchain (xcodebuild/simctl)       sees ONLY your git repo + its own home
  your git identity + forwarded SSH agent   commits as you; keys stay on the host
```

`xcbox` mounts the **git repo root** (so `.git` is available and commit/push work even when
the Xcode project is in a subdirectory), and drops you into your working directory inside it.
The build MCP is registered with the agent at user scope; the agent drives real `xcodebuild`
on the host and the results round-trip back.

## Requirements

Apple Silicon · macOS 26+ · Xcode 26+ · Apple `container` CLI · a global git identity ·
an SSH agent with a key loaded. Check everything with:

```bash
bin/xcbox doctor
```

## Commands

| Command | Description |
|---|---|
| `xcbox` / `xcbox up` | bring up the gateway + repo sandbox and enter it |
| `xcbox status` | gateway / box / agent / MCP state for this project |
| `xcbox stop` | stop this project's box (`--gateway` also stops the gateway) |
| `xcbox logs` | tail the build gateway log |
| `xcbox rm` | remove this project's box (keeps `~/.xcbox-home`) |
| `xcbox doctor` | check host prerequisites |

The agent home (login, installed agent) persists in `~/.xcbox-home` across runs.
See [`docs/xcbox-quickstart.md`](docs/xcbox-quickstart.md) for the full walkthrough.

## Tests

Standalone bash scripts, run directly:

```bash
bin/test-guard.sh bin/test-lib.sh bin/test-dispatch.sh bin/test-doctor.sh bin/test-subcommands.sh
bin/test-gateway.sh      # starts the gateway; checks a real MCP session
bin/test-loop.sh         # full end-to-end: generate a throwaway app → build + test through the sandbox
```

## Threat model

**Trusted-agent.** The sandbox isolates the agent's *filesystem* to your repo (guarding against
mistakes and blast radius, not a malicious agent). Builds still run your project's build scripts
on the host via `xcodebuild`. The gateway binds the host-only vmnet with **no authentication** —
don't run `xcbox` on shared or multi-user machines without a firewall rule restricting `:8765`.
