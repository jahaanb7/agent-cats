# Agent Cats

A native macOS companion that shows every running **Claude Code** and **Codex** session as a pixel-art cat on a little cat tree under the menu bar. Each cat reacts to what its agent is actually doing. Clicking the tree opens a hardware-style dashboard.

Status: **Phase 1, event plumbing.** The menu-bar widget comes in Phase 2.

## What works now

- **Session detection** for Claude Code (`~/.claude/projects/*/*.jsonl`) and Codex (`~/.codex/sessions/**/rollout-*.jsonl`). Files are followed with FSEvents (no polling) and live `claude`/`codex` processes are matched by launch folder.
- **Normalized state machine:** idle, thinking, working, permission, question, done, error and gone. Process exits are caught right away with kqueue.
- **Real metrics only:** tokens (input/output/cache), cache hit rate, model, title, and Claude Code's own cost estimate (`cost-state`). For Codex there are context-window use, 5-hour and weekly rate limits, and plan. Anything an agent doesn't report shows as `–`.
- **Hook bridge** (`agentcats-hook`). Takes about 11 ms, prints nothing, always exits 0, and spools to disk if the app isn't running. Claude Code and Codex share one hook format.
- **Hook installer:** a dry-run diff that edits only the `"hooks"` block, timestamped backups, and a clean uninstall. Existing hooks are kept.
- **Dynamic tree sizing:** the tree grows by one perch per session.
  - Up to about 10 cats it stays at full size (1.5pt per art pixel).
  - With more, it shrinks to 1pt.
  - Beyond that, calm cats sleep in a "+N" basket.
  - Cats that need you are never hidden.

## Build and try

```sh
./build.sh                       # swiftc only, works with Command Line Tools (no Xcode needed)
./dist/agentcats selftest        # fixture tests
./dist/agentcats watch           # live terminal view of all sessions and the tree layout
./dist/agentcats sessions --json
./dist/agentcats layout --width 680
./dist/agentcats hooks plan      # shows the exact config diff; writes nothing
```

Hooks are only written with `./dist/agentcats hooks install --yes`, and `hooks uninstall --yes` removes them again. Without hooks, everything still works from the logs, but permission prompts are detected later.

## Layout

| Path | What |
|---|---|
| `Sources/Shared/` | libproc helpers and paths (shared with the hook) |
| `Sources/Core/` | models, parsers, session store, monitor, socket server, installer, tree layout |
| `Sources/CLI/` | `agentcats` dev CLI and self-tests |
| `Sources/Hook/` | `agentcats-hook` |
| `Art/cats.json` | sprite source: palette-indexed grids, 8 coats, poses, props |

Everything stays on your Mac. There are no network calls.
