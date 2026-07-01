<p align="center">
  <img src="misc/logo.png" alt="xcbox logo" width="200">
</p>

<h1 align="center">xcbox</h1>

<p align="center">
  <b>Run a coding agent in a sandbox scoped to your Xcode/Swift project.</b><br>
  The agent sees only your repo — yet it builds, tests, and runs on the host, and commits as you.
</p>

---

`xcbox` drops a coding agent (e.g. [Claude Code](https://www.claude.com/product/claude-code))
into a Linux container with **only your project's git repository** mounted — nothing else of your
machine is visible. The agent still builds and tests the real app **on the host** via
[XcodeBuildMCP](https://github.com/cameroncooke/XcodeBuildMCP), and commits & pushes with **your
git identity over your forwarded SSH agent** — your keys never enter the container.

## Highlights

- **One command.** `cd` into any Xcode/Swift project and run `xcbox`.
- **Project-scoped sandbox.** The agent's filesystem is limited to your repo; the rest of the host stays invisible.
- **Real host builds.** `xcodebuild` and simulators run on macOS through XcodeBuildMCP — full fidelity, no toolchain shipped in the container.
- **Commits as you.** Uses your host git identity and forwarded SSH agent; private keys stay on the host.
- **Every Apple platform**, plus Swift packages — because XcodeBuildMCP drives them all.

## Install

Put `xcbox` on your `PATH` (symlinks `bin/xcbox` into a bin dir already on your `PATH`):

```bash
git clone git@github.com:Bunn/xcbox.git && cd xcbox
./install.sh                 # auto-picks a writable dir on PATH
```

`./install.sh /usr/local/bin` installs into a specific dir; `./install.sh --uninstall` removes it.
The symlink resolves back to the repo, so `git pull` updates the installed command. Prefer not to
install? Just run `bin/xcbox` directly.

## Quickstart

```bash
cd ~/YourApp
xcbox                        # brings up the sandbox and drops you into a shell
```

Inside the box, start your agent and point it at the project:

```
claude
/login                       # one-time; the login persists in ~/.xcbox-home
> Build and test this app, then commit and push.
```

Run `xcbox doctor` first if you want to check prerequisites. Full walkthrough:
[`docs/xcbox-quickstart.md`](docs/xcbox-quickstart.md).

## How it works

```
HOST (macOS)                                CONTAINER (Linux · repo-only)
  XcodeBuildMCP behind a stateful             your agent (e.g. Claude Code)
  HTTP gateway on :8765  ◄───────────────────  connects over 192.168.64.1:8765
  Xcode toolchain (xcodebuild / simctl)       sees ONLY your git repo + its own home
  your git identity + forwarded SSH agent     commits as you; keys stay on the host
```

`xcbox` mounts the **git repository root** (so `.git` is present and commit/push work even when
the Xcode project lives in a subdirectory) and drops you into your working directory inside it. The
build server is registered with the agent at user scope; the agent calls real `xcodebuild` on the
host and the results stream back over the gateway.

## Requirements

Apple Silicon · macOS 26+ · Xcode 26+ · Apple [`container`](https://github.com/apple/container)
CLI · a global git identity · an SSH agent with a key loaded.

```bash
xcbox doctor                 # checks all of the above
```

## Commands

| Command | Description |
| --- | --- |
| `xcbox` · `xcbox up` | bring up the gateway + repo sandbox and enter it |
| `xcbox status` | show gateway / box / agent / MCP state for this project |
| `xcbox stop` | stop this project's box (`--gateway` also stops the gateway) |
| `xcbox logs` | tail the build gateway log |
| `xcbox rm` | remove this project's box (keeps `~/.xcbox-home`) |
| `xcbox doctor` | check host prerequisites |

The agent's home — login and installed agent — persists in `~/.xcbox-home` across runs and boxes.

## Tests

Standalone bash scripts, run directly:

```bash
bin/test-guard.sh bin/test-lib.sh bin/test-dispatch.sh bin/test-doctor.sh bin/test-subcommands.sh
bin/test-gateway.sh          # starts the gateway; verifies a real MCP session
bin/test-loop.sh             # full end-to-end: generate a throwaway app → build + test through the sandbox
```

## Security model

**Trusted-agent.** The sandbox isolates the agent's *filesystem* to your repository — it guards
against mistakes and blast radius, not a malicious agent. Builds still run your project's build
scripts on the host via `xcodebuild`, and the container keeps network access (it must reach the
gateway). The gateway binds a host-only network with **no authentication**, so don't run `xcbox` on
a shared or multi-user machine without a firewall rule restricting port `8765`.
