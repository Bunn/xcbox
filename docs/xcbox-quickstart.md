# xcbox Quickstart (Phase 1)

A one-command sandboxed iOS coding agent. The agent sees ONLY your project and
builds/tests on the host via XcodeBuildMCP.

## Prerequisites

Configure Apple container's localhost DNS bridge, then run `bin/xcbox doctor`:

```bash
sudo container system dns create host.container.internal --localhost 203.0.113.113
bin/xcbox doctor
```

The bridge lets the sandbox reach the build gateway while it remains bound only
to host loopback. Doctor also checks Apple Silicon, macOS, Xcode, Node.js 20+, the `container`
CLI, your git identity, and an SSH agent with a key. Fix any `FAIL` line before
continuing. The bridge rule may need to be recreated after a restart.

On first use, xcbox runs `npm ci` to install the exact MCP SDK and XcodeBuildMCP
versions in the repository's `package-lock.json`. The stateful HTTP bridge itself
ships with xcbox. It reuses the locked runtime—including offline—and reinstalls
only when the lockfile changes.

## First run

```bash
cd ~/YouriOSApp
/path/to/ios-agent-sandbox/bin/xcbox     # = 'xcbox up'
```

This first asks you to choose Claude Code or Codex. xcbox brings up the build
gateway, creates a project-only sandbox, installs that agent in this project's
isolated home, wires your git identity and the build MCP, remembers the choice,
and drops you into a shell. Later bare `xcbox` runs reuse the saved agent. Then:

```bash
claude            # if you selected Claude Code
# or
codex              # if you selected Codex
```

Sign in only if prompted. To switch later, run `xcbox --agent codex` or
`xcbox --agent claude`; the new selection is remembered and both agents keep
their separate state. `XCBOX_AGENT=codex xcbox` is available for scripts.

Ask the agent: **"Build and test this app, then commit and push."** It uses the
`ios-build` MCP tools (`discover_projs`, `build_sim`, `test_sim`) and pushes via
your forwarded SSH agent — as your git identity, with keys that never enter the box.

## Lifecycle

```bash
xcbox status            # verify host + box gateway, MCP tools, agent, and SSH forwarding
xcbox list              # inventory every box and retained project home
xcbox logs              # tail the gateway log (-f follows; --lines N controls history)
xcbox stop              # stop this project's box
xcbox stop --gateway    # also stop the host gateway
xcbox rm                # remove this project's box (keeps ~/.xcbox-home)
```

## Manual end-to-end confirmation (the Phase 1 "it's a thing" proof)

```bash
# 1. Generate a throwaway app with a scratch GitHub remote.
D=$(mktemp -d)/IosboxDemo; mkdir -p "$D/Sources" "$D/Tests"
# (use the project.yml / App.swift / MathsTests.swift from bin/test-loop.sh)
( cd "$D" && xcodegen generate && git init -q && git add -A && git commit -qm init )
gh repo create xcbox-demo-scratch --private --source "$D" --remote origin --push

# 2. Box up, log in, drive the agent.
cd "$D" && /path/to/ios-agent-sandbox/bin/xcbox
#   choose an agent, then inside: claude or codex → "build, test, commit, and push this app"

# 3. Confirm the commit on the remote, then tear down.
gh repo view xcbox-demo-scratch --json pushedAt
gh repo delete xcbox-demo-scratch --yes
cd / && xcbox rm && rm -rf "$D"
```

**Success:** the agent builds + tests the app via the MCP tools and the commit
appears on the GitHub remote.
