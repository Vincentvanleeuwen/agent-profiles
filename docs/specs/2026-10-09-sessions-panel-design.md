# Sessions side panel — design

Date: 2026-10-09. Status: approved in brainstorming, waiting for spec review.

## Goal

Replace the buggy sessions dropdown of the `hud` mod with a side panel that lists this profile's sessions, opens one with a single click, and shows enough detail to tell sessions apart. Every session the launcher starts runs in the background, so a session can always be opened from another terminal.

Success: the switch never picks the wrong terminal. When it cannot be sure, it says so instead of guessing.

## Where the code lives

| Part | Location | Version control |
| --- | --- | --- |
| Launcher (`_cp_launch`) | this repo, `lib/commands.sh`, Windows twin in `agent-profile.psm1` | git |
| Launcher tests | this repo, `test.sh` (`test.ps1` for Windows) | git |
| `hud` mod | `~/.agents/skills/hud` (`hooks/hud.tsx`, `hooks/sessions.tsx`, `types/index.d.ts`) | none; edit in place |
| Mod tests | `~/.agents/skills/hud/tests/hud.test.ts` (`claude-code/testing` harness) | none |
| End-to-end script | `~/.agents/skills/hud/tests/e2e/` | none |

The switch loop in `_cp_launch` from 2026-10-06 is staged but not committed. This work builds on it.

## Background facts (verified 2026-10-09, Claude Code 2.1.295)

- `claude --bg [args]` starts a background session and returns at once. It prints `backgrounded · <id> · <name> …`. It refuses a folder the person has not trusted yet ("Workspace not trusted").
- `claude attach <id>` shows a background session in the terminal. Ending that process (SIGTERM) leaves the terminal clean and the session running.
- `/exit` inside an attached session does not stop it. It opens Claude Code's agent view (the built-in session list).
- After the person uses agent view (← on an empty prompt, or `/exit`), the attach process renames itself to `claude agents` (same pid) and keeps that name, even after they open a session again. No file, socket or journal tells which session it shows; only the background service knows.
- `disableAgentView: true` also blocks `claude attach`, so agent view cannot be turned off.
- `claude agents --json` lists the current profile's sessions. Fields: `id` (job id, background only), `sessionId`, `name`, `cwd`, `kind` (`background` / `interactive`), `status`, `state` (background only), `pid`, `startedAt`. Fresh background sessions report `status: idle` with `state: blocked`.
- A mod opens a pane with `$.ui.open({ id })` and draws it from `ui.render` for `{ component: 'Pane' }`. In fullscreen at 110 columns or more it docks beside the transcript; otherwise it sits above the prompt. Attached sessions always draw fullscreen. A pane opened without a press waits undrawn below 110 columns (144 if never opened by hand).
- The hud mod runs inside the session process, not in the terminal process that shows it.

## 1. Launcher

`_cp_launch` classifies the call by its first argument only:

| First argument | Action |
| --- | --- |
| none | background start |
| starts with `-`, and no argument is `-p`, `--print`, `-h`, `--help`, `-v`, `--version`, `--bg`, `--background` | background start |
| contains a space (a prompt) | background start |
| anything else (subcommand, one-word prompt) | run unchanged |

A one-word prompt (`claude fix`) cannot be told apart from a subcommand and runs in the foreground. A comment in the code states this limit.

Background start:

1. Run `claude --bg "$@"` with its output captured. Read the id from `backgrounded · <id>`.
2. If the run fails or no id is found, run `claude "$@"` in the foreground. The person then sees the trust prompt or the real error.
3. Otherwise run `claude attach <id>`.
4. The existing switch loop follows: while the switch file holds an id, `claude attach <that id>`. Ids with characters outside `A-Za-z0-9._-` are refused, as today.

The same change goes into `agent-profile.psm1`. `pwsh` is not installed on the development machine, so that change carries a comment saying it is untested.

## 2. Button and panel

The button stays in the HUD row with its current label (`Sessions · 4 · 1 needs you · * 2`) and hotkey `s`. Pressing it opens or closes the pane `hud-sessions` (title `Sessions`). The old dropdown, its scrolling, "more" rows and backdrop are removed.

Pane layout:

```
Sessions                              ↻  ✕
frontend · 2
  ⠋ off-3665-dimensions     working 3m  ■
    feat/OFF-3665-… · "fix the cleared side…"
  ▸ hud-panel  (here)          idle 12m
    main · "design a sessions side panel…"
agent-profiles · 1
  * launcher-fix               idle 1h  ■
    main · "make every start a backgro…"
```

- Line 1: status mark (`●` needs you, spinner working, `*` idle), name, duration, stop button.
- Line 2, dimmed: git branch and the first part of the last prompt.
- Groups: the current session's repository first, then the others alphabetically. Within a group: needs you, working, idle.
- Clicking a row opens that session. The current session shows `▸ … (here)`, cannot be clicked and has no stop button.
- `■` stops after a confirm: the first click turns the row's button into `stop? ■`; a second click within 5 seconds stops the session; otherwise the row returns to normal. Interactive sessions have no stop button.
- `↻` refreshes the list. `✕` closes the pane.
- Inline (above the prompt), the pane asks for as many rows as the list needs.

Staying open across switches: opening the pane writes `$CLAUDE_CONFIG_DIR/hud/panel-open`. On `session.start` the mod reopens the pane when that file exists. `✕`, or Escape closing the pane (`ui.close` with origin `person`), deletes the file. Below 110 columns a reopened pane stays hidden until the person presses the button (a Claude Code rule).

## 3. Data

Session list: `claude agents --json`. Status mapping from `status`: `busy` → working, `waiting` → needs you, `idle` → idle; `state` is not used. During implementation, a test session with a pending permission prompt confirms which value "needs you" produces. The tests record the result.

Activity file: each session's own hud mod writes `$CLAUDE_CONFIG_DIR/hud/activity/<sessionId>.json` at the start and end of each main-loop turn (no `agentId`):

```json
{ "sessionId": "…", "promptAt": 0, "finishedAt": 0, "lastPrompt": "first 80 characters", "branch": "main", "repoRoot": "/path/to/repo" }
```

The activity file is joined to the list by `sessionId`. The implementation verifies that `$.session.id()` matches `sessionId` from `claude agents --json`, including for a resumed session whose job id differs.

Duration: working → now minus `promptAt`; idle → now minus `finishedAt`; no activity file → idle since `startedAt`. Format: `now` (under a minute), `4m`, `2h`, `3d`.

Repository: `git rev-parse --path-format=absolute --git-common-dir`; the repository name is the folder that holds the common `.git`, so worktrees group under their main repository. The session's activity file supplies it. Without one, the panel runs the command on the session's `cwd` and caches the result per folder. Outside git, the group is the folder name.

Refresh: the list and durations refresh every 15 seconds while the pane is open, and after each main-loop turn. The spinner only runs while the pane is open.

Cleanup: on refresh, delete activity files not modified for 7 days.

## 4. Opening and stopping

Opening session T from the current session S:

1. T is `interactive` (its own foreground terminal) → notice: it is open in its own terminal and cannot be moved here.
2. S is `interactive` (the untrusted-folder fallback) → read `CLAUDE_PROFILE_SWITCH_FILE` from S's own environment, write T's job id to it, run `/background`. The launcher attaches T. Missing variable → notice to start claude from a new tab.
3. S is `background` → find candidate terminal processes:
   - `ps -axo pid=,tty=,command=`: a `claude` program on a real tty (not `??`), excluding the background service's helpers (`daemon`, `bg-spare`, `bg-pty-host`).
   - Same profile: `CLAUDE_CONFIG_DIR` in the process environment (`ps -wwE`) equals this session's.
   - Arguments are `attach <S job id>`, `agents`, or `attach <x>` where x is not another listed session's exact job id (an attach by name may be S).
   - Exactly one candidate → read its `CLAUDE_PROFILE_SWITCH_FILE`, write T's job id, end the process with SIGTERM. No switch file → notice that this terminal was not started by the launcher.
   - Zero, or two or more candidates → notice: `Press ← and pick "<T>"`. Never guess.

The `panel-open` file stays, so T reopens the pane.

Stop: `claude stop <job id>`, then refresh. A non-zero exit shows the first stderr line as a notice.

Notices are amber, at the bottom of the pane, and clear on the next action. A failing `claude agents --json` shows the reason; `↻` retries.

## 5. Testing

1. Mod unit tests (`tests/hud.test.ts`):
   - Grouping (worktree, non-git folder), duration text, status mapping, stop confirm and its 5-second timeout.
   - Candidate deduction from `ps` fixtures: exact attach, renamed to `agents`, attach by name, other profile, two candidates, zero candidates, no switch file.
   - Pane behaviour: the button opens the pane; `✕` and Escape close it and delete `panel-open`; `session.start` with `panel-open` reopens it; a row click writes the right id and ends the right pid.
2. Launcher tests (`test.sh`, fake `claude` through `_CP_RUNNER`): the classification table above, `--bg` failure fallback, the attach loop.
3. End-to-end (`tests/e2e/`, run by hand against the real Claude Code in tmux):
   - Start two background sessions through the launcher in a trusted folder; send one tiny prompt so activity times exist.
   - Open the pane with `s`; check groups, durations and `(here)` in the captured screen.
   - Switch to the other session; check the terminal shows it and the pane is open.
   - `/exit`, return to the session, switch again; it succeeds (one candidate).
   - Stop with confirm; check the session is gone from `claude agents --json`.
   - Run at 160 columns (docked) and 100 columns (inline). Stop every test session at the end.

## Out of scope

- Sessions of other profiles.
- Turning off ← or agent view.
- Putting the `hud` mod under version control.
