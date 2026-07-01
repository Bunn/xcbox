# xcbox Quickstart (Phase 1)

A one-command sandboxed iOS coding agent. The agent sees ONLY your project and
builds/tests on the host via XcodeBuildMCP.

## Prerequisites

Run `bin/xcbox doctor` — it checks Apple Silicon, macOS, Xcode, the `container`
CLI, your git identity, and an SSH agent with a key. Fix any `FAIL` line before
continuing.

## First run

```bash
cd ~/YouriOSApp
/path/to/ios-agent-sandbox/bin/xcbox     # = 'xcbox up'
```

This brings up the build gateway, creates a project-only sandbox, installs the
agent (first time only), wires your git identity + the build MCP, and drops you
into a shell. Then:

```bash
claude            # start the agent
/login            # one-time; open the printed URL on the host, paste the code back
```

Ask the agent: **"Build and test this app, then commit and push."** It uses the
`ios-build` MCP tools (`discover_projs`, `build_sim`, `test_sim`) and pushes via
your forwarded SSH agent — as your git identity, with keys that never enter the box.

## Lifecycle

```bash
xcbox status            # gateway/box/agent/MCP state for this project
xcbox logs              # tail the gateway log
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
#   inside: claude → /login → "build, test, commit, and push this app"

# 3. Confirm the commit on the remote, then tear down.
gh repo view xcbox-demo-scratch --json pushedAt
gh repo delete xcbox-demo-scratch --yes
cd / && xcbox rm && rm -rf "$D"
```

**Success:** the agent builds + tests the app via the MCP tools and the commit
appears on the GitHub remote.
