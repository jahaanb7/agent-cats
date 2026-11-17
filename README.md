# Agent Cats

A native macOS companion that represents running **Claude Code** and **Codex** sessions as pixel-art cats in a little room under the menu bar. It stays tucked away with only a pull rope visible. Click or tug the rope (or click the menu-bar paw) to reveal the room. New permission requests, questions, or errors reveal it automatically. Click a cat and it tells you what it needs in a speech bubble. Answer right there, or double-click the cat to jump to its terminal.

Status: **Native cat tree and live session dashboard implemented.** Claude Code permission requests can be allowed or denied from the dashboard after installing the updated hooks. Codex approvals and typed answers remain in the agent’s window.

## What works now

- **Retractable room:** wallpaper, an evening window, wooden floor, and animated pixel cats. Click/tug the rope to show or hide it; the × button and a click outside the app also tuck it away. Dismissed alerts stay dismissed until a new attention event arrives. Automatic reveals close when attention clears; manually opened rooms stay open until dismissed. Hidden cats stop their animation timer. Reduced-motion settings skip the reveal animation.
- **Talking cats:** click a cat and a speech bubble pops out above it. The text types itself out and the cat hops. The bubble shows what the agent wants: its question with the suggested answers as buttons, a permission request with Allow/Deny, or its last reply when it finishes. A text box takes your own answer. Cats speak up on their own when they need permission, ask a question, finish, or hit an error. Questions wait until answered; finished and status bubbles fade after a few seconds. Press Esc or click elsewhere to close.
  - **Double-click** a cat to jump to its Terminal or iTerm2 tab, or to its app for IDE sessions.
  - **Right-click** a cat for: What do you need?, Open terminal, Open project folder, and Show details… (the full session dashboard).
  - **How answers reach the agent:** if a Claude permission request is being held by the hook, the bubble answers the hook directly. Text you type there denies the request and passes your words to Claude. Everything else is typed into the session's own terminal tab, which is found by its tty. iTerm2 receives the text in the background. Terminal.app is brought forward, sent the keys, and then you're returned to your previous app; this needs Accessibility permission, which is requested the first time. Before every key, the app checks that the right tab is still in front. If the tab moved or the agent has already moved on, nothing is typed. Other terminals and IDEs can't have a specific pane targeted, so the bubble asks you to double-click instead.
- **Live dashboard:** right-click a cat → Show details…, or click the tree / menu-bar paw, to see all sessions, or click the tree / menu-bar paw to see all sessions, including overflow cats. Includes activity history, reported metrics, project-folder access, and a jump to the agent window.
- **Claude approvals:** review the complete tool input, then Allow once, Deny, or Handle in agent. Each live request has its own identity; disconnected, expired, and already-resolved requests cannot be approved. After two minutes, the hook returns control to the normal agent prompt.
- **Hook setup:** the dashboard previews the exact settings diff and installs only when you click Install hooks. Existing hooks are preserved and files are backed up. Restart agent sessions afterward.
- **Attention requests:** permissions and questions stand out in the dashboard. Codex decisions and typed answers still happen in the agent itself.

- **Session detection** for Claude Code (`~/.claude/projects/*/*.jsonl`) and Codex (`~/.codex/sessions/**/rollout-*.jsonl`). Files are followed with FSEvents (no polling) and live `claude`/`codex` processes are matched by launch folder.
- **Normalized state machine:** idle, thinking, working, permission, question, done, error and gone. Process exits are caught right away with kqueue.
- **Real metrics only:** tokens (input/output/cache), cache hit rate, model, title, and Claude Code's own cost estimate (`cost-state`). For Codex there are context-window use, 5-hour and weekly rate limits, and plan. Anything an agent doesn't report shows as `–`.
- **Hook bridge** (`agentcats-hook`). Ordinary events print nothing and spool to disk if the app is unavailable. Claude PermissionRequest hooks installed with `--approvals` wait up to 120 seconds for a user decision and emit only the supported decision JSON. Spool replay never creates actionable approvals. All paths exit 0 so an unavailable bridge falls back to the agent’s normal flow.
- **Hook installer:** a dry-run diff that edits only the `"hooks"` block, timestamped backups, and a clean uninstall. Existing hooks are kept.
- **Dynamic tree sizing:** the tree grows by one perch per session.
  - Up to about 10 cats it stays at full size (1.5pt per art pixel).
  - With more, it shrinks to 1pt.
  - Beyond that, calm cats sleep in a "+N" basket.
  - Cats that need you are never hidden.

## Open the app

Open `~/Applications/AgentCats.app` in Finder. Explicitly opening or reopening the app reveals the room; tuck it away with the rope or ×. For a hidden launch, pass `--background` to the executable.

If Finder appears to do nothing, double-click `Start Agent Cats.command` in this project folder. It launches the executable from your desktop session and reports startup errors. Diagnostics are saved to `~/Library/Logs/AgentCats/startup.log` and `launch.log`.

Builds are staged and signed before replacing the runnable bundle, so failed builds preserve the previous app.

## Build and try

```sh
./build.sh                       # swiftc only, works with Command Line Tools (no Xcode needed)
open dist/AgentCats.app          # launch the native widget and dashboard
./dist/agentcats selftest        # fixture tests
./Tests/run-socket-tests.sh      # real Unix-socket integration checks
./Tests/run-room-tests.sh        # native rope/layout checks + room/rope preview PNGs
./Tests/run-bubble-preview.sh    # renders the speech bubble's moods to dist/bubble-preview.png
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
| `Sources/App/` | AppKit widget, sprite renderer, SwiftUI dashboard, terminal navigation |
| `Sources/CLI/` | `agentcats` dev CLI and self-tests |
| `Sources/Hook/` | `agentcats-hook` |
| `Art/cats.json` | sprite source: palette-indexed grids, 8 coats, poses, props |

Everything stays on your Mac. There are no network calls.

## Approval behavior and remaining work

The Claude decision format follows the [official PermissionRequest hook reference](https://code.claude.com/docs/en/hooks#permissionrequest-decision-control). Only an explicit click on a live request produces an allow or deny decision. No permanent permission rules are added. AskUserQuestion answers are typed into the terminal from the cat's bubble (option N types N; your own text picks the "type something" entry first). A CLI-only `watch` listener acknowledges immediately because it has no approval UI. Only one listener can own the socket at a time.

Native room rendering, rope hit testing, tug/accessibility activation, and visibility transitions are tested. Still to verify on an unrestricted desktop: real Unix-socket integration tests, full desktop interaction, and a live Claude permission round trip. This development sandbox denies Unix-socket binding and does not support the menu-bar app lifecycle reliably. Codex decision transport is not implemented; Codex replies from the bubble are typed into its terminal (y/n for approvals). The keystroke mappings for Claude Code's and Codex's terminal UIs still need a live check on a real desktop.
