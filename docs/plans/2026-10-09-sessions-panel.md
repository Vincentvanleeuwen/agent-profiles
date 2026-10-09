# Sessions side panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hud mod's sessions dropdown with a docked side panel that lists this profile's sessions grouped by repository, opens one with a click, and stops one with a confirmed click; make every launcher start a background session.

**Architecture:** The launcher (`lib/commands.sh`) starts `claude --bg`, then `claude attach <id>`, then the existing switch loop. The hud mod keeps every `$`-using function in `hooks/hud.tsx` (a mod rule: `$` may only be passed to functions in the same file) and moves pure logic into `hooks/session-list.ts` (parsing, grouping, durations), `hooks/session-switch.ts` (which terminal to switch) and `hooks/sessions-panel.tsx` (drawing).

**Tech Stack:** POSIX sh (launcher), Claude Code mod API 2.1.295 (`$.ui.open`, `ui.render` for `Pane`), `claude-code/testing` run by `claude plugin test`, tmux for the end-to-end run.

**Spec:** `docs/specs/2026-10-09-sessions-panel-design.md`

## Global Constraints

- Only the current profile's sessions (`claude agents --json` under the session's own `CLAUDE_CONFIG_DIR`).
- Pane id `hud-sessions-panel`, title `Sessions`, opened with `closeOnEscape: true`.
- Activity file: `<config dir>/hud/activity/<sessionId>.json`; panel flag: `<config dir>/hud/panel-open`. `<config dir>` is `CLAUDE_CONFIG_DIR`, or `$HOME/.claude` when unset.
- Duration text: `now` under a minute, then `4m`, `2h`, `3d`. Working counts from the last prompt, idle from the last finish, no activity file from `startedAt`.
- Status mapping from `status` only: `busy` → working, `waiting` → needs you, `idle` → idle, anything else → idle.
- Stop confirm window: 5 seconds. Panel refresh: every 15 seconds while open. Activity files kept 7 days.
- Never guess a terminal: exactly one candidate or a notice.
- The `hud` mod (`~/.agents/skills/hud`) has no version control: its tasks end with a full test run, not a commit. Launcher tasks commit in this repo.
- Code style: match the files (no semicolons, 2-space indent in TS; names over comments; at most one-line comments for a *why*).

## Review Focus

1. A session started before this update has no activity file: it must still list, group by its folder's repository, and show `idle <time since start>`.
2. A terminal that went through agent view (`claude agents`) must still be found when it is the only one; two such terminals must give the notice, not a switch.
3. A click on `✕` in session A, then a switch to session B whose pane is still open: B must close its pane (the flag is gone).
4. `claude --bg` failing (untrusted folder) must start a foreground session with the same arguments, not leave the person at the shell.
5. A row's stop pressed once, then left alone for 5 seconds, must return to `■`; pressed twice within 5 seconds must run `claude stop`.

Each item has a test in the owning task (Tasks 1, 3, 5, 6).

## Deviation from the spec

The spec mirrors the launcher change in `agent-profile.psm1`. That file has no switch loop at all, and the mod's terminal switch needs `ps`, which Windows lacks. A background-by-default Windows launcher would therefore make switching worse, untested. Task 1 only extends the existing Windows comment to say why. This is reported to the person at hand-over.

## File Structure

| File | Responsibility |
| --- | --- |
| `lib/commands.sh` | `_cp_starts_in_background` (which calls start in the background) and `_cp_launch` (start, attach, switch loop) |
| `test.sh` | launcher tests |
| `agent-profile.psm1` | comment only |
| `~/.agents/skills/hud/types/index.d.ts` | `HudSession`, `HudActivity`, plugin state |
| `~/.agents/skills/hud/hooks/session-list.ts` | new: parse sessions, mood, label, durations, grouping, activity parsing |
| `~/.agents/skills/hud/hooks/session-switch.ts` | new: switch plan, terminal candidates, terminal choice |
| `~/.agents/skills/hud/hooks/sessions-panel.tsx` | new: draws the pane body |
| `~/.agents/skills/hud/hooks/sessions.tsx` | deleted (its logic moves to the three files above) |
| `~/.agents/skills/hud/hooks/hud.tsx` | band button, pane lifecycle, activity writer, open and stop actions |
| `~/.agents/skills/hud/tests/hud.test.ts` | engine-level tests (existing file) |
| `~/.agents/skills/hud/tests/session-logic.test.ts` | new: tests of the pure files |
| `~/.agents/skills/hud/tests/e2e/sessions-panel.sh` | new: tmux end-to-end run |

Run mod tests: `cd ~/.agents/skills/hud && ~/.local/bin/claude plugin test .`
Run launcher tests: `cd ~/agent-profiles && sh test.sh`

---

### Task 1: Launcher starts sessions in the background

**Files:**
- Modify: `lib/commands.sh` (`_cp_launch`, new `_cp_starts_in_background` above it)
- Modify: `test.sh` (after the `== Session switch ==` block)
- Modify: `agent-profile.psm1:507` (comment)

**Interfaces:**
- Produces: `_cp_starts_in_background "$@"` → exit 0 for a background start, 1 to run unchanged.

- [ ] **Step 1: Write the failing tests** (append after the malformed-id test in `test.sh`)

```sh
echo "== Background start =="

# Stands in for claude: --bg prints the id the way 2.1.295 does, or fails like an untrusted folder.
_cp_bg_runner() {
    printf '%s\n' "$*" >> "$TMP/bg-calls"
    if [ "$1" = --bg ]; then
        [ -z "$_bg_fails" ] || { echo 'Workspace not trusted.'; return 1; }
        printf 'backgrounded · job-1 · probe (idle — send a prompt to start)\n  claude agents  list sessions\n'
    fi
}

bg_calls() {
    rm -f "$TMP/bg-calls"
    _CP_RUNNER='_cp_bg_runner' _cp_launch "$(_cp_dir dev)" "$@" >/dev/null 2>&1
    cat "$TMP/bg-calls"
}

eq "no arguments start in the background" "$(bg_calls)" "$(printf -- '--bg\nattach job-1')"
eq "flags start in the background" "$(bg_calls --model opus)" "$(printf -- '--bg --model opus\nattach job-1')"
eq "a prompt starts in the background" "$(bg_calls 'fix the test')" "$(printf -- '--bg fix the test\nattach job-1')"
eq "a subcommand runs unchanged" "$(bg_calls agents)" "agents"
eq "print mode runs unchanged" "$(bg_calls -p hi)" "-p hi"
eq "a one-word prompt runs unchanged" "$(bg_calls fix)" "fix"
eq "an explicit --bg runs unchanged" "$(bg_calls --bg 'do it')" "--bg do it"
_bg_fails=1
eq "a refused background start runs in the foreground" "$(bg_calls --model opus)" "$(printf -- '--bg --model opus\n--model opus')"
unset _bg_fails
```

- [ ] **Step 2: Run to verify they fail**

Run: `sh test.sh 2>&1 | grep -A12 'Background start'`
Expected: FAIL lines for the five background cases (calls show no `--bg`).

- [ ] **Step 3: Implement** (replace `_cp_launch` in `lib/commands.sh`)

```sh
# Plain starts become background sessions shown with `claude attach`, so the
# hud panel can open any session in any terminal. A subcommand, a one-word
# prompt (it reads like a subcommand) and print/help/version run unchanged.
_cp_starts_in_background() {
    [ $# -eq 0 ] && return 0
    case "$1" in
        -*|*' '*) ;;
        *) return 1 ;;
    esac
    for _sb_arg in "$@"; do
        case "$_sb_arg" in
            -p|--print|-h|--help|-v|--version|--bg|--background) return 1 ;;
        esac
    done
    return 0
}

# Single choke point for starting a session: pull shared prompt state in,
# run, push back whatever this session accepted.
_cp_launch() {
    _l_dir="$1"; shift
    _l_switch="${TMPDIR:-/tmp}/agent-profile-switch.$$"
    rm -f "$_l_switch"
    _cp_sync_prompts "$_l_dir"
    _l_rc=0
    _l_job=
    if _cp_starts_in_background "$@"; then
        _l_job=$(CLAUDE_CONFIG_DIR="$_l_dir" _cp_run_claude --bg "$@" 2>&1 |
            sed -n 's/^backgrounded · \([A-Za-z0-9._-]*\) .*/\1/p' | head -n 1)
    fi
    if [ -n "$_l_job" ]; then
        printf '%s' "$_l_job" > "$_l_switch"
    else
        # Refused (an untrusted folder): the foreground run shows the trust prompt or the real error.
        CLAUDE_CONFIG_DIR="$_l_dir" CLAUDE_PROFILE_SWITCH_FILE="$_l_switch" _cp_run_claude "$@"
        _l_rc=$?
    fi
    # A session switcher (the hud mod) writes the session to open next here,
    # then ends the display or its own foreground run.
    while [ -s "$_l_switch" ]; do
        _l_target=$(cat "$_l_switch")
        rm -f "$_l_switch"
        case "$_l_target" in
            *[!A-Za-z0-9._-]*) printf 'claude-profile: ignored a session switch to "%s"\n' "$_l_target" >&2; break ;;
        esac
        CLAUDE_CONFIG_DIR="$_l_dir" CLAUDE_PROFILE_SWITCH_FILE="$_l_switch" _cp_run_claude attach "$_l_target"
        _l_rc=$?
    done
    _cp_sync_prompts "$_l_dir"
    return $_l_rc
}
```

And in `agent-profile.psm1`, replace the comment line in `Start-CpClaude` with:

```powershell
    # No background start or session switch loop here: the hud mod finds the terminal to switch with `ps`, which Windows lacks.
```

- [ ] **Step 4: Run to verify they pass**

Run: `sh test.sh 2>&1 | tail -3`
Expected: `all passed`

- [ ] **Step 5: Commit** (the staged switch loop from 2026-10-06 goes in with it; this builds on it)

```bash
git add lib/commands.sh test.sh agent-profile.psm1
git commit -m "feat: start every claude session in the background"
```

---

### Task 2: Pure session-list logic

**Files:**
- Modify: `~/.agents/skills/hud/types/index.d.ts`
- Create: `~/.agents/skills/hud/hooks/session-list.ts`
- Create: `~/.agents/skills/hud/tests/session-logic.test.ts`

**Interfaces:**
- Produces (from `session-list.ts`): `readSessions(stdout, currentSessionId, home): HudSession[]`, `moodOf(session): SessionMood`, `sessionsLabel(sessions): string`, `formatDuration(ms): string`, `describeTime(session, activity | undefined, now): string`, `describeWork(session, activity | undefined): string`, `repoRootFromGitDir(text): string | null`, `groupSessions(sessions, activity, repoRoots): SessionGroup[]`, `promptPreview(text): string`, `readActivity(text): HudActivity | null`, `IDLE_MARK`, types `SessionMood`, `SessionGroup`.

- [ ] **Step 1: Update the types** (`types/index.d.ts`: replace `HudSession` and the `hud` plugin state)

```ts
export type HudSession = {
  sessionId: string
  // What `claude attach` takes; a resumed session runs under a new job id.
  jobId: string
  name: string
  // The cwd with the home folder shortened to `~`.
  folder: string
  cwd: string
  isBackground: boolean
  status: string
  startedAt: number
  isCurrent: boolean
}

export type HudActivity = {
  sessionId: string
  promptAt: number | null
  finishedAt: number | null
  lastPrompt: string
  branch: string | null
  repoRoot: string | null
}

declare module 'claude-code' {
  interface PluginState {
    hud: {
      snapshot: HudSnapshot
      isModelMenuOpen: boolean
      isContextOpen: boolean
      sessions: HudSession[]
      sessionsError: string | null
      sessionsNotice: string | null
      activity: Record<string, HudActivity>
      // The repository root per session folder, for sessions without an activity file.
      repoRoots: Record<string, string | null>
      stopArmedFor: string | null
      spinnerFrame: number
    }
  }
}
```

- [ ] **Step 2: Write the failing tests** (`tests/session-logic.test.ts`)

```ts
import { describe, expect, test } from 'claude-code/testing'

import type { HudActivity, HudSession } from '../types'
import {
  describeTime,
  describeWork,
  formatDuration,
  groupSessions,
  promptPreview,
  readActivity,
  readSessions,
  repoRootFromGitDir,
} from '../hooks/session-list'

const NOW = Date.parse('2026-10-09T12:00:00Z')
const MINUTE = 60_000

function session(overrides: Partial<HudSession>): HudSession {
  return {
    sessionId: 'session-a',
    jobId: 'job-a',
    name: 'a',
    folder: '~/frontend',
    cwd: '/Users/someone/frontend',
    isBackground: true,
    status: 'idle',
    startedAt: NOW - 60 * MINUTE,
    isCurrent: false,
    ...overrides,
  }
}

function activity(overrides: Partial<HudActivity>): HudActivity {
  return { sessionId: 'session-a', promptAt: null, finishedAt: null, lastPrompt: '', branch: null, repoRoot: null, ...overrides }
}

describe('reading the session list', () => {
  test('keeps the start time, the full folder and whether it runs in the background', () => {
    const stdout = JSON.stringify([
      { id: 'job-a', sessionId: 'session-a', name: 'a', cwd: '/Users/someone/frontend', kind: 'background', status: 'busy', startedAt: 5 },
      { sessionId: 'session-b', name: '', cwd: '/Users/someone/order-api', kind: 'interactive', status: 'idle' },
    ])

    expect(readSessions(stdout, 'session-b', '/Users/someone')).toEqual([
      session({ status: 'busy', startedAt: 5 }),
      session({
        sessionId: 'session-b',
        jobId: 'session-b',
        name: 'order-api',
        folder: '~/order-api',
        cwd: '/Users/someone/order-api',
        isBackground: false,
        startedAt: 0,
        isCurrent: true,
      }),
    ])
  })

  test('returns nothing for output that is not a JSON list', () => {
    expect(readSessions('not json', 'x', '/home')).toEqual([])
    expect(readSessions('{}', 'x', '/home')).toEqual([])
  })
})

describe('durations', () => {
  test('read as now, minutes, hours and days', () => {
    expect(formatDuration(59_000)).toBe('now')
    expect(formatDuration(4 * MINUTE)).toBe('4m')
    expect(formatDuration(150 * MINUTE)).toBe('2h')
    expect(formatDuration(3 * 24 * 60 * MINUTE)).toBe('3d')
  })

  test('a working session counts from its last prompt', () => {
    const working = session({ status: 'busy' })

    expect(describeTime(working, activity({ promptAt: NOW - 3 * MINUTE, finishedAt: NOW - 9 * MINUTE }), NOW)).toBe('working 3m')
  })

  test('a working session whose new prompt is not recorded yet has just started', () => {
    const working = session({ status: 'busy' })

    expect(describeTime(working, activity({ promptAt: NOW - 9 * MINUTE, finishedAt: NOW - 5 * MINUTE }), NOW)).toBe('working now')
  })

  test('an idle session counts from its last finish', () => {
    expect(describeTime(session({}), activity({ promptAt: NOW - 20 * MINUTE, finishedAt: NOW - 12 * MINUTE }), NOW)).toBe('idle 12m')
  })

  test('a session waiting for you counts from its last prompt', () => {
    expect(describeTime(session({ status: 'waiting' }), activity({ promptAt: NOW - 2 * MINUTE }), NOW)).toBe('needs you 2m')
  })

  test('a session without an activity file is idle since it started', () => {
    expect(describeTime(session({}), undefined, NOW)).toBe('idle 1h')
  })
})

describe('the second line of a row', () => {
  test('shows the branch and the start of the last prompt', () => {
    expect(describeWork(session({}), activity({ branch: 'main', lastPrompt: 'fix the test' }))).toBe('main · "fix the test"')
  })

  test('falls back to the folder without an activity file', () => {
    expect(describeWork(session({}), undefined)).toBe('~/frontend')
  })

  test('a prompt preview is one line of at most 80 characters', () => {
    expect(promptPreview('  fix\n\nthe   test ')).toBe('fix the test')
    expect(promptPreview('x'.repeat(100))).toHaveLength(80)
  })
})

describe('grouping', () => {
  test('a worktree belongs to its main repository', () => {
    expect(repoRootFromGitDir('/Users/someone/frontend/.git\n')).toBe('/Users/someone/frontend')
    expect(repoRootFromGitDir('/Users/someone/bare.git')).toBe('/Users/someone/bare.git')
    expect(repoRootFromGitDir('')).toBeNull()
  })

  test('groups by repository, the current one first, then by name, needs-you first inside', () => {
    const sessions = [
      session({ sessionId: 's1', name: 'docs', cwd: '/x/zeta' }),
      session({ sessionId: 's2', name: 'idle one', cwd: '/x/frontend-worktrees/off-1' }),
      session({ sessionId: 's3', name: 'asks', cwd: '/x/frontend', status: 'waiting' }),
      session({ sessionId: 's4', name: 'cli', cwd: '/x/alpha', isCurrent: true }),
    ]
    const activities = { s2: activity({ sessionId: 's2', repoRoot: '/x/frontend' }) }
    const repoRoots = { '/x/frontend': '/x/frontend', '/x/zeta': null, '/x/alpha': '/x/alpha' }

    expect(groupSessions(sessions, activities, repoRoots).map(group => [group.name, group.sessions.map(s => s.name)])).toEqual([
      ['alpha', ['cli']],
      ['frontend', ['asks', 'idle one']],
      ['zeta', ['docs']],
    ])
  })
})

describe('reading an activity file', () => {
  test('accepts a complete record and refuses anything else', () => {
    const record = activity({ promptAt: 1, finishedAt: 2, lastPrompt: 'hi', branch: 'main', repoRoot: '/x' })

    expect(readActivity(JSON.stringify(record))).toEqual(record)
    expect(readActivity('{"sessionId": 3}')).toBeNull()
    expect(readActivity('nope')).toBeNull()
  })
})
```

- [ ] **Step 3: Run to verify they fail**

Run: `claude plugin test .`
Expected: FAIL, `Cannot find module '../hooks/session-list'`.

- [ ] **Step 4: Implement** (`hooks/session-list.ts`)

```ts
import type { HudActivity, HudSession } from '../types'

export type SessionMood = 'needsYou' | 'working' | 'idle'

export type SessionGroup = { name: string; sessions: HudSession[] }

const STATUS_MOODS: Record<string, SessionMood> = { busy: 'working', waiting: 'needsYou', idle: 'idle' }
const MOOD_ORDER: Record<SessionMood, number> = { needsYou: 0, working: 1, idle: 2 }
const MOOD_WORDS: Record<SessionMood, string> = { needsYou: 'needs you', working: 'working', idle: 'idle' }
const PROMPT_PREVIEW_CHARS = 80

export const IDLE_MARK = '*'

export function readSessions(stdout: string, currentSessionId: string, home: string): HudSession[] {
  let rows: unknown

  try {
    rows = JSON.parse(stdout)
  } catch {
    return []
  }

  if (!Array.isArray(rows)) {
    return []
  }

  return rows.flatMap(raw => {
    const row = raw as Partial<Record<'id' | 'sessionId' | 'name' | 'cwd' | 'kind' | 'status' | 'startedAt', unknown>>

    if (typeof row.sessionId !== 'string') {
      return []
    }

    const cwd = typeof row.cwd === 'string' ? row.cwd : ''
    const folder = home !== '' && cwd.startsWith(home) ? `~${cwd.slice(home.length)}` : cwd

    return [
      {
        sessionId: row.sessionId,
        jobId: typeof row.id === 'string' ? row.id : row.sessionId,
        name: typeof row.name === 'string' && row.name.trim() !== '' ? row.name.trim() : (folder.split('/').pop() ?? 'session'),
        folder,
        cwd,
        isBackground: row.kind !== 'interactive',
        status: typeof row.status === 'string' ? row.status : 'idle',
        startedAt: typeof row.startedAt === 'number' ? row.startedAt : 0,
        isCurrent: row.sessionId === currentSessionId,
      },
    ]
  })
}

export function moodOf(session: HudSession): SessionMood {
  return STATUS_MOODS[session.status] ?? 'idle'
}

export function sessionsLabel(sessions: readonly HudSession[]): string {
  if (sessions.length === 0) {
    return 'Sessions'
  }

  const otherSessions = sessions.filter(session => !session.isCurrent)
  const waiting = otherSessions.filter(session => moodOf(session) === 'needsYou').length
  const idle = otherSessions.filter(session => moodOf(session) === 'idle').length
  const parts = [`Sessions · ${sessions.length}`]

  if (waiting > 0) {
    parts.push(`${waiting} need${waiting === 1 ? 's' : ''} you`)
  }

  if (idle > 0) {
    parts.push(`${IDLE_MARK} ${idle}`)
  }

  return parts.join(' · ')
}

export function formatDuration(milliseconds: number): string {
  const minutes = Math.floor(milliseconds / 60_000)

  if (minutes < 1) {
    return 'now'
  }

  if (minutes < 60) {
    return `${minutes}m`
  }

  const hours = Math.floor(minutes / 60)

  return hours < 24 ? `${hours}h` : `${Math.floor(hours / 24)}d`
}

export function describeTime(session: HudSession, activity: HudActivity | undefined, now: number): string {
  const mood = moodOf(session)

  return `${MOOD_WORDS[mood]} ${formatDuration(Math.max(0, now - activeSince(mood, session, activity, now)))}`
}

function activeSince(mood: SessionMood, session: HudSession, activity: HudActivity | undefined, now: number): number {
  if (activity === undefined) {
    return session.startedAt
  }

  if (mood === 'idle') {
    return activity.finishedAt ?? session.startedAt
  }

  const isPromptRecorded = activity.promptAt !== null && (activity.finishedAt === null || activity.promptAt > activity.finishedAt)

  return isPromptRecorded && activity.promptAt !== null ? activity.promptAt : now
}

export function describeWork(session: HudSession, activity: HudActivity | undefined): string {
  if (activity === undefined) {
    return session.folder
  }

  const prompt = activity.lastPrompt === '' ? [] : [`"${activity.lastPrompt}"`]

  return [activity.branch ?? session.folder, ...prompt].join(' · ')
}

export function promptPreview(text: string): string {
  return text.replace(/\s+/g, ' ').trim().slice(0, PROMPT_PREVIEW_CHARS)
}

export function repoRootFromGitDir(gitCommonDir: string): string | null {
  const trimmed = gitCommonDir.trim().replace(/\/+$/, '')

  if (trimmed === '') {
    return null
  }

  return trimmed.endsWith('/.git') ? trimmed.slice(0, -'/.git'.length) : trimmed
}

export function groupSessions(
  sessions: readonly HudSession[],
  activity: Readonly<Record<string, HudActivity>>,
  repoRoots: Readonly<Record<string, string | null>>,
): SessionGroup[] {
  const members = new Map<string, HudSession[]>()

  for (const session of sessions) {
    const name = groupName(session.cwd, activity[session.sessionId]?.repoRoot ?? repoRoots[session.cwd] ?? null)
    members.set(name, [...(members.get(name) ?? []), session])
  }

  const groups = [...members].map(([name, grouped]) => ({
    name,
    sessions: [...grouped].sort((left, right) => MOOD_ORDER[moodOf(left)] - MOOD_ORDER[moodOf(right)]),
  }))
  const currentGroup = groups.find(group => group.sessions.some(session => session.isCurrent))?.name

  return groups.sort((left, right) => {
    if (left.name === currentGroup || right.name === currentGroup) {
      return left.name === currentGroup ? -1 : 1
    }

    return left.name.localeCompare(right.name)
  })
}

function groupName(cwd: string, repoRoot: string | null): string {
  const path = (repoRoot ?? cwd).replace(/\/+$/, '')
  const name = path.slice(path.lastIndexOf('/') + 1)

  return name === '' ? 'session' : name
}

export function readActivity(text: string): HudActivity | null {
  let record: Partial<Record<keyof HudActivity, unknown>>

  try {
    record = JSON.parse(text) as Partial<Record<keyof HudActivity, unknown>>
  } catch {
    return null
  }

  const isTime = (value: unknown) => value === null || typeof value === 'number'
  const isText = (value: unknown) => value === null || typeof value === 'string'

  if (
    record === null ||
    typeof record.sessionId !== 'string' ||
    !isTime(record.promptAt) ||
    !isTime(record.finishedAt) ||
    typeof record.lastPrompt !== 'string' ||
    !isText(record.branch) ||
    !isText(record.repoRoot)
  ) {
    return null
  }

  return record as HudActivity
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `claude plugin test .`
Expected: the new `session-logic` tests pass. `hud.test.ts` still passes, because `sessions.tsx` still exists until Task 5.

---

### Task 3: Which terminal to switch

**Files:**
- Create: `~/.agents/skills/hud/hooks/session-switch.ts`
- Modify: `~/.agents/skills/hud/tests/session-logic.test.ts` (append)

**Interfaces:**
- Consumes: `HudSession` (Task 2).
- Produces: `planSwitch(target, current | undefined, ownSwitchFile | undefined): SwitchPlan`, `terminalCandidates(psOutput, current, sessions): number[]`, `chooseTerminal(candidates, envOutput, configDir | undefined, targetName): TerminalChoice`, `SWITCH_NOTICES`.

- [ ] **Step 1: Write the failing tests** (append; add the import at the top)

```ts
import { SWITCH_NOTICES, chooseTerminal, planSwitch, terminalCandidates } from '../hooks/session-switch'

describe('planning a switch', () => {
  const current = session({ sessionId: 'here', jobId: 'job-here', isCurrent: true })
  const target = session({ sessionId: 'there', jobId: 'job-there', name: 'there' })

  test('a session in its own terminal cannot be opened here', () => {
    expect(planSwitch(session({ ...target, isBackground: false }), current, '/tmp/s')).toEqual({
      route: 'refuse',
      reason: SWITCH_NOTICES.ownTerminal('there'),
    })
  })

  test('a background session switches its terminal', () => {
    expect(planSwitch(target, current, undefined)).toEqual({ route: 'terminal' })
  })

  test('a foreground session uses its own switch file', () => {
    expect(planSwitch(target, { ...current, isBackground: false }, '/tmp/s')).toEqual({ route: 'self', switchFile: '/tmp/s' })
    expect(planSwitch(target, { ...current, isBackground: false }, undefined)).toEqual({
      route: 'refuse',
      reason: SWITCH_NOTICES.notFromLauncher,
    })
  })

  test('without knowing this session it points to agent view', () => {
    expect(planSwitch(target, undefined, '/tmp/s')).toEqual({ route: 'refuse', reason: SWITCH_NOTICES.pickInAgentView('there') })
  })
})

describe('finding the terminal that shows this session', () => {
  const current = session({ sessionId: 'here', jobId: 'job-here', isCurrent: true })
  const sessions = [current, session({ sessionId: 'other', jobId: 'job-other' })]
  const ps = [
    '  101 ttys001  /Users/someone/.local/bin/claude attach job-here',
    '  102 ttys002  /Users/someone/.local/bin/claude agents',
    '  103 ttys003  /Users/someone/.local/bin/claude attach job-other',
    '  104 ttys004  /Users/someone/.local/bin/claude attach hud panel',
    '  105 ??       /Users/someone/.local/bin/claude daemon run --origin transient',
    '  106 ttys006  /Users/someone/.local/bin/claude --model opus',
    '  107 ttys007  /usr/bin/vim attach job-here',
  ].join('\n')

  test('keeps exact attaches, agent view and attaches by name, nothing else', () => {
    expect(terminalCandidates(ps, current, sessions)).toEqual([101, 102, 104])
  })

  const environments = [
    '101 /Users/someone/.local/bin/claude attach job-here TERM=xterm CLAUDE_CONFIG_DIR=/p/designer CLAUDE_PROFILE_SWITCH_FILE=/tmp/switch.1',
    '102 /Users/someone/.local/bin/claude agents CLAUDE_CONFIG_DIR=/p/default CLAUDE_PROFILE_SWITCH_FILE=/tmp/switch.2',
    '104 /Users/someone/.local/bin/claude attach hud panel CLAUDE_CONFIG_DIR=/p/designer',
  ].join('\n')

  test('exactly one terminal in this profile is the one', () => {
    expect(chooseTerminal([101, 102], environments, '/p/designer', 'there')).toEqual({ pid: 101, switchFile: '/tmp/switch.1' })
  })

  test('two terminals in this profile give a notice, never a guess', () => {
    expect(chooseTerminal([101, 104], environments, '/p/designer', 'there')).toEqual({ reason: SWITCH_NOTICES.pickInAgentView('there') })
  })

  test('no terminal gives the same notice', () => {
    expect(chooseTerminal([], '', '/p/designer', 'there')).toEqual({ reason: SWITCH_NOTICES.pickInAgentView('there') })
  })

  test('a terminal the launcher did not open says so', () => {
    expect(chooseTerminal([104], environments, '/p/designer', 'there')).toEqual({
      reason: SWITCH_NOTICES.terminalNotFromLauncher('there'),
    })
  })
})
```

- [ ] **Step 2: Run to verify they fail**

Run: `claude plugin test .`
Expected: FAIL, `Cannot find module '../hooks/session-switch'`.

- [ ] **Step 3: Implement** (`hooks/session-switch.ts`)

```ts
import type { HudSession } from '../types'

// `self`: this session runs in the foreground of a launcher terminal and steps into the background.
// `terminal`: this session runs in the background, so the terminal that shows it is found and ended.
export type SwitchPlan = { route: 'self'; switchFile: string } | { route: 'terminal' } | { route: 'refuse'; reason: string }

export type TerminalChoice = { pid: number; switchFile: string } | { reason: string }

export const SWITCH_NOTICES = {
  alreadyHere: 'You are already in this session.',
  ownTerminal: (name: string) => `"${name}" is open in its own terminal, so it can't be opened here.`,
  notFromLauncher: 'This session was not started by the claude launcher. Open a new terminal tab and start claude there.',
  pickInAgentView: (name: string) => `Couldn't tell which terminal shows this session. Press ← on an empty prompt, then pick "${name}".`,
  terminalNotFromLauncher: (name: string) =>
    `This terminal was not opened by the claude launcher. Press ← on an empty prompt, then pick "${name}".`,
}

export function planSwitch(target: HudSession, current: HudSession | undefined, ownSwitchFile: string | undefined): SwitchPlan {
  if (target.isCurrent) {
    return { route: 'refuse', reason: SWITCH_NOTICES.alreadyHere }
  }

  if (!target.isBackground) {
    return { route: 'refuse', reason: SWITCH_NOTICES.ownTerminal(target.name) }
  }

  if (current === undefined) {
    return { route: 'refuse', reason: SWITCH_NOTICES.pickInAgentView(target.name) }
  }

  if (current.isBackground) {
    return { route: 'terminal' }
  }

  return ownSwitchFile === undefined || ownSwitchFile === ''
    ? { route: 'refuse', reason: SWITCH_NOTICES.notFromLauncher }
    : { route: 'self', switchFile: ownSwitchFile }
}

// A terminal showing this session is `claude attach <its id>`, or `claude agents` once agent view was used
// (the process keeps that name after opening a session from there). An attach by name may be this session too.
export function terminalCandidates(psOutput: string, current: HudSession, sessions: readonly HudSession[]): number[] {
  const otherJobIds = new Set(sessions.filter(session => !session.isCurrent).map(session => session.jobId))

  return psOutput.split('\n').flatMap(line => {
    const match = /^\s*(\d+)\s+(\S+)\s+(.*)$/.exec(line)

    if (match === null) {
      return []
    }

    const [, pid = '', tty = '', command = ''] = match
    const [program = '', ...args] = command.trim().split(/\s+/)
    const attached = args.slice(1).join(' ')
    const isClaudeOnATerminal = tty !== '??' && program.split('/').pop() === 'claude'
    const showsAgentView = args.length === 1 && args[0] === 'agents'
    const mayShowThisSession = args[0] === 'attach' && attached !== '' && (attached === current.jobId || !otherJobIds.has(attached))

    return isClaudeOnATerminal && (showsAgentView || mayShowThisSession) ? [Number(pid)] : []
  })
}

export function chooseTerminal(
  candidates: readonly number[],
  envOutput: string,
  configDir: string | undefined,
  targetName: string,
): TerminalChoice {
  const environments = new Map(
    envOutput.split('\n').flatMap(line => {
      const match = /^\s*(\d+)\s+(.*)$/.exec(line)

      return match === null ? [] : [[Number(match[1]), match[2] ?? ''] as const]
    }),
  )
  const inThisProfile = candidates.flatMap(pid => {
    const environment = environments.get(pid)

    return environment !== undefined && environmentValue(environment, 'CLAUDE_CONFIG_DIR') === configDir ? [{ pid, environment }] : []
  })
  const [only] = inThisProfile

  if (inThisProfile.length !== 1 || only === undefined) {
    return { reason: SWITCH_NOTICES.pickInAgentView(targetName) }
  }

  const switchFile = environmentValue(only.environment, 'CLAUDE_PROFILE_SWITCH_FILE')

  return switchFile === undefined ? { reason: SWITCH_NOTICES.terminalNotFromLauncher(targetName) } : { pid: only.pid, switchFile }
}

// `ps -wwE` prints the environment after the command, space separated; profile paths hold no spaces.
function environmentValue(environment: string, name: string): string | undefined {
  return new RegExp(`(?:^|\\s)${name}=(\\S+)`).exec(environment)?.[1]
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `claude plugin test .`
Expected: all tests pass.

---

### Task 4: Each session records its activity

**Files:**
- Modify: `~/.agents/skills/hud/hooks/hud.tsx` (imports, new functions, `turn.start` and `turn.complete` hooks)
- Modify: `~/.agents/skills/hud/tests/hud.test.ts` (in-memory files in `engineBeneath`, new tests)

**Interfaces:**
- Consumes: `promptPreview`, `repoRootFromGitDir` (Task 2).
- Produces in `hud.tsx`: `hudFolder($): Promise<string>`, `readRepoRoot($, cwd): Promise<string | null>`, `recordPrompt($, text)`, `recordFinish($)`, module variable `ownActivity`.

- [ ] **Step 1: Give the test engine in-memory files** (in `engineBeneath`, replace the `fs.write` stub and the `process.run` stub; add the `files` parameter last)

```ts
type ProcessReply = { exitCode: number; stdout: string; stderr: string }

function engineBeneath(
  on: On,
  ranCommands: string[],
  paneEvents: string[] = [],
  written: Written[] = [],
  switchFile = '/tmp/agent-profile-switch.42',
  processStdout: (argv: readonly string[]) => string | ProcessReply = defaultProcessStdout,
  place: Place = { sessionId: 'session-this', cwd: '/work/frontend' },
  files: Map<string, string> = new Map(),
): ReturnType<typeof mock.clock> {
  const openPanes = new Set<string>()
  on('fs.write', ($, e) => {
    written.push({ path: e.path, text: e.text })
    files.set(e.path, e.text)
    return { value: undefined }
  })
  on('fs.read', ($, e) => {
    const text = files.get(e.path)
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })
  on('fs.exists', ($, e) => ({ value: files.has(e.path) }))
  on('fs.list', ($, e) => ({
    value: [...files.keys()]
      .filter(path => path.startsWith(`${e.path}/`))
      .map(path => ({ name: path.slice(e.path.length + 1), kind: 'file', size: 1, mtimeMs: NOW, isLink: false })),
  }))
  on('ui.open', ($, e) => {
    paneEvents.push(`open ${e.id}`)
    openPanes.add(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.close', ($, e) => {
    paneEvents.push(`close ${e.id} ${e.origin.kind}`)
    openPanes.delete(e.id)
    return { value: undefined }
  })
  on('ui.panes', () => ({ value: [...openPanes].map(id => ({ id, title: id, isPlaced: true })) }))
  // ...the existing clock, env, session and settings stubs stay as they are...
  on('process.run', ($, e) => {
    if (e.argv[0] === 'rm') {
      files.delete(e.argv[2] ?? '')
    }
    const reply = processStdout(e.argv)
    const { exitCode, stdout, stderr } = typeof reply === 'string' ? { exitCode: 0, stdout: reply, stderr: '' } : reply
    return { value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } }
  })
  // ...command.run and the AbovePrompt render stub stay...
}
```

Also make `defaultProcessStdout` answer `git rev-parse`:

```ts
function defaultProcessStdout(argv: readonly string[]): string {
  if (argv[0] === 'claude') return JSON.stringify(SESSION_ROWS)
  if (argv[1] === 'rev-parse') return '/work/frontend/.git\n'
  return 'feat/OFF-3665-dimensions\n'
}
```

The exact shapes of the `fs.read`, `fs.exists`, `fs.list` and `ui.panes` events come from `.claude-plugin/types/claude-code/index.d.ts` in the dev-mod copy. If a stub's field name differs (for example `e.path`), follow the type file.

- [ ] **Step 2: Write the failing tests** (new `describe` at the end of `hud.test.ts`)

```ts
const ACTIVITY_FILE = '/Users/someone/.agent-profiles/profiles/designer/hud/activity/session-this.json'

describe('the activity file', () => {
  test('a prompt records when it started, its first words, the branch and the repository', async ($, on) => {
    const files = new Map<string, string>()
    const clock = engineBeneath(on, [], [], [], '/tmp/s', defaultProcessStdout, undefined, files)
    await startSession($)

    await $.turn.start({ text: 'fix\nthe   cleared side', turnId: 't1' })

    expect(JSON.parse(files.get(ACTIVITY_FILE) ?? '')).toEqual({
      sessionId: 'session-this',
      promptAt: NOW,
      finishedAt: null,
      lastPrompt: 'fix the cleared side',
      branch: 'feat/OFF-3665-dimensions',
      repoRoot: '/work/frontend',
    })

    await clock.advance(60_000)
    await $.turn.complete({ turnId: 't1' })

    expect(JSON.parse(files.get(ACTIVITY_FILE) ?? '')).toMatchObject({ promptAt: NOW, finishedAt: NOW + 60_000 })
  })

  test('a turn without typed text keeps the last prompt', async ($, on) => {
    const files = new Map<string, string>()
    engineBeneath(on, [], [], [], '/tmp/s', defaultProcessStdout, undefined, files)
    await startSession($)

    await $.turn.start({ text: 'first', turnId: 't1' })
    await $.turn.start({ text: '', turnId: 't2' })

    expect(JSON.parse(files.get(ACTIVITY_FILE) ?? '')).toMatchObject({ lastPrompt: 'first' })
  })

  test('a subagent turn records nothing', async ($, on) => {
    const files = new Map<string, string>()
    engineBeneath(on, [], [], [], '/tmp/s', defaultProcessStdout, undefined, files)
    await startSession($)

    await $.turn.start({ text: 'look around', turnId: 't1', agentId: 'agent-1' })

    expect(files.has(ACTIVITY_FILE)).toBe(false)
  })
})
```

How the test engine raises `turn.start` and `turn.complete` (`$.turn.start(...)`) follows the existing `turn.complete` usage in the testing types. If `turn.complete` needs more fields, copy them from the type file.

- [ ] **Step 3: Run to verify they fail**

Run: `claude plugin test .`
Expected: the three activity tests FAIL (no file written).

- [ ] **Step 4: Implement** (in `hud.tsx`)

Imports and state:

```ts
import type { HudActivity, HudContextSlice, HudRateLimit, HudSession, HudSnapshot } from '../types'
import { promptPreview, repoRootFromGitDir } from './session-list'

let ownActivity: HudActivity | null = null
```

Functions (next to `readBranch`):

```ts
async function hudFolder($: EngineInterface): Promise<string> {
  const [configDir, home] = await Promise.all([$.env.get('CLAUDE_CONFIG_DIR'), $.env.get('HOME')])

  return `${(configDir ?? `${home ?? ''}/.claude`).replace(/\/+$/, '')}/hud`
}

async function readRepoRoot($: EngineInterface, cwd: string): Promise<string | null> {
  const result = await $.process
    .run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd })
    .catch(() => null)

  return result === null || result.exitCode !== 0 ? null : repoRootFromGitDir(result.stdout)
}

async function recordPrompt($: EngineInterface, text: string): Promise<void> {
  const [sessionId, cwd, now] = await Promise.all([$.session.id(), $.session.cwd(), $.clock.now()])
  const [branch, repoRoot] = await Promise.all([readBranch($, cwd), readRepoRoot($, cwd)])
  const earlier = ownActivity?.sessionId === sessionId ? ownActivity : null
  const preview = promptPreview(text)

  ownActivity = {
    sessionId,
    promptAt: now,
    finishedAt: earlier?.finishedAt ?? null,
    lastPrompt: preview === '' ? (earlier?.lastPrompt ?? '') : preview,
    branch,
    repoRoot,
  }
  await $.fs.write(`${await hudFolder($)}/activity/${sessionId}.json`, JSON.stringify(ownActivity))
}

async function recordFinish($: EngineInterface): Promise<void> {
  const [sessionId, now] = await Promise.all([$.session.id(), $.clock.now()])
  const earlier = ownActivity?.sessionId === sessionId ? ownActivity : null

  ownActivity = {
    sessionId,
    promptAt: earlier?.promptAt ?? null,
    finishedAt: now,
    lastPrompt: earlier?.lastPrompt ?? '',
    branch: earlier?.branch ?? null,
    repoRoot: earlier?.repoRoot ?? null,
  }
  await $.fs.write(`${await hudFolder($)}/activity/${sessionId}.json`, JSON.stringify(ownActivity))
}
```

Hooks (replace the existing `turn.start` hook; extend `turn.complete`):

```ts
  on('turn.start', async ($, e, next) => {
    await closeMenus($)

    if (e.agentId === undefined) {
      await recordPrompt($, e.text)
    }

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const completed = await next(e)

    if (e.agentId === undefined) {
      await recordFinish($)
      await refreshEverything($)
      await refreshSessions($)
    }

    return completed
  })
```

- [ ] **Step 5: Run to verify they pass**

Run: `claude plugin test .`
Expected: all tests pass.

---

### Task 5: The side panel replaces the dropdown

**Files:**
- Create: `~/.agents/skills/hud/hooks/sessions-panel.tsx`
- Delete: `~/.agents/skills/hud/hooks/sessions.tsx`
- Modify: `~/.agents/skills/hud/hooks/hud.tsx`
- Modify: `~/.agents/skills/hud/tests/hud.test.ts` (delete the dropdown tests at old lines 274-495: "puts the one waiting for you first", "starts at the Sessions button", "only one menu is open…", "a long sessions list scrolls…", "the sessions list shows every session…", and the four switch tests; they are rewritten here and in Task 6)

**Interfaces:**
- Consumes: Task 2 exports, `hudFolder`, `readRepoRoot` (Task 4).
- Produces: `PANEL_ID = 'hud-sessions-panel'`, `SPINNER_FRAMES`, `drawSessionsPanel(kit, input: PanelInput)`; in `hud.tsx`: `toggleSessionsPanel($)`, `closeSessionsPanel($)`, `showSessionsPanel($)`, `syncPanelWithFlag($)`, `refreshSessions($)` (now also activity and repo roots), atoms `activityValue`, `repoRootsValue`, `stopArmedFor`, and `openSession($, target)` / `stopSession($, target)` with temporary bodies that Task 6 replaces.

- [ ] **Step 1: Write the failing tests** (in the `the HUD band` describe, replacing the deleted ones)

```ts
const PANE = {
  plugin: 'hud',
  component: 'Pane',
  requestId: 'hud-sessions-panel',
  props: { title: 'Sessions', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 30 }, view: {} },
} as const
const PANEL_FLAG = '/Users/someone/.agent-profiles/profiles/designer/hud/panel-open'

  test('the Sessions button opens the side panel and remembers it is open', async ($, on) => {
    const paneEvents: string[] = []
    const files = new Map<string, string>()
    engineBeneath(on, [], paneEvents, [], '/tmp/s', defaultProcessStdout, undefined, files)
    await startSession($)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })

    await band.press({ key: 'hud-sessions' })

    expect(paneEvents).toContain('open hud-sessions-panel')
    expect(files.has(PANEL_FLAG)).toBe(true)

    await band.press({ key: 'hud-sessions' })

    expect(paneEvents).toContain('close hud-sessions-panel plugin')
    expect(files.has(PANEL_FLAG)).toBe(false)
  })

  test('the panel groups sessions by repository with a status, a duration and a second line', async ($, on) => {
    const rows = [
      { sessionId: 'session-this', name: 'hud work', cwd: '/work/frontend', kind: 'background', status: 'busy', startedAt: NOW - 600_000 },
      { id: 'job-idle', sessionId: 'session-idle', name: 'order api cleanup', cwd: '/work/order-api', kind: 'background', status: 'idle', startedAt: NOW - 7_200_000 },
    ]
    const files = new Map([
      [
        '/Users/someone/.agent-profiles/profiles/designer/hud/activity/session-idle.json',
        JSON.stringify({ sessionId: 'session-idle', promptAt: NOW - 1_800_000, finishedAt: NOW - 720_000, lastPrompt: 'drop the old route', branch: 'main', repoRoot: '/work/order-api' }),
      ],
    ])
    engineBeneath(on, [], [], [], '/tmp/s', argv => (argv[0] === 'claude' ? JSON.stringify(rows) : defaultProcessStdout(argv)), undefined, files)
    await startSession($)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'hud-sessions' })
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    const texts = (await pane.findAll({ type: 'Text' })).map(found => found.text)

    expect(texts).toEqual(expect.arrayContaining(['frontend · 1', 'order-api · 1', 'hud work  (here)', '  idle 12m', 'main · "drop the old route"']))
    expect(texts.indexOf('frontend · 1') < texts.indexOf('order-api · 1')).toBe(true)
    expect(await pane.find({ type: 'Button', key: 'hud-panel-open-session-idle', text: 'order api cleanup' })).toBeDefined()
    expect(await pane.find({ type: 'Button', key: 'hud-panel-open-session-this' })).toBeUndefined()
    expect(await pane.find({ type: 'Button', key: 'hud-panel-stop-session-this' })).toBeUndefined()
  })

  test('a session without an activity file groups by its folder\'s repository and is idle since it started', async ($, on) => {
    const rows = [{ id: 'job-old', sessionId: 'session-old', name: 'old one', cwd: '/work/zeta', kind: 'background', status: 'idle', startedAt: NOW - 3_600_000 }]
    engineBeneath(on, [], [], [], '/tmp/s', argv => {
      if (argv[0] === 'claude') return JSON.stringify(rows)
      if (argv[1] === 'rev-parse') return '/work/zeta/.git\n'
      return 'main\n'
    })
    await startSession($)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'hud-sessions' })
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    const texts = (await pane.findAll({ type: 'Text' })).map(found => found.text)

    expect(texts).toEqual(expect.arrayContaining(['zeta · 1', '  idle 1h', '/work/zeta']))
  })

  test('the panel\'s close button closes it and forgets it was open', async ($, on) => {
    const paneEvents: string[] = []
    const files = new Map<string, string>()
    engineBeneath(on, [], paneEvents, [], '/tmp/s', defaultProcessStdout, undefined, files)
    await startSession($)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'hud-sessions' })
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })

    await pane.press({ key: 'hud-panel-close' })

    expect(paneEvents).toContain('close hud-sessions-panel plugin')
    expect(files.has(PANEL_FLAG)).toBe(false)
  })

  test('closing the panel by hand forgets it was open', async ($, on) => {
    const files = new Map<string, string>()
    engineBeneath(on, [], [], [], '/tmp/s', defaultProcessStdout, undefined, files)
    await startSession($)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'hud-sessions' })

    await $.ui.close({ id: 'hud-sessions-panel', origin: { kind: 'person' } })

    expect(files.has(PANEL_FLAG)).toBe(false)
  })

  test('a session that finds the panel remembered as open opens it again', async ($, on) => {
    const paneEvents: string[] = []
    const files = new Map([[PANEL_FLAG, '1']])
    engineBeneath(on, [], paneEvents, [], '/tmp/s', defaultProcessStdout, undefined, files)

    await startSession($)

    expect(paneEvents).toContain('open hud-sessions-panel')
  })

  test('a session whose panel was closed elsewhere closes it when it is shown again', async ($, on) => {
    const paneEvents: string[] = []
    const files = new Map([[PANEL_FLAG, '1']])
    const clock = engineBeneath(on, [], paneEvents, [], '/tmp/s', defaultProcessStdout, undefined, files)
    await startSession($)
    files.delete(PANEL_FLAG)

    await clock.advance(2_000)
    await $.ui.mount({ ...BAND, surface: 'terminal' })
    await clock.advance(0)

    expect(paneEvents).toContain('close hud-sessions-panel plugin')
  })

  test('the panel shows a spinner for working sessions while it is open', async ($, on) => {
    const clock = engineBeneath(on, [])
    await startSession($)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'hud-sessions' })
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })

    expect(await pane.find({ type: 'Text', text: '⠋ ' })).toBeDefined()

    await clock.advance(100)

    expect(await pane.find({ type: 'Text', text: '⠙ ' })).toBeDefined()
  })
```

- [ ] **Step 2: Run to verify they fail**

Run: `claude plugin test .`
Expected: the new panel tests FAIL (no `ui.open`, no Pane drawing).

- [ ] **Step 3: Implement the drawing** (`hooks/sessions-panel.tsx`)

```tsx
import type { BoxProps, ButtonProps, ElementConstructor, RenderElement, TextProps } from 'claude-code'

import type { HudActivity, HudSession } from '../types'

import { IDLE_MARK, describeTime, describeWork, moodOf } from './session-list'
import type { SessionGroup } from './session-list'

export const PANEL_ID = 'hud-sessions-panel'
export const SPINNER_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'] as const

const COLORS = {
  lavender: '#c4b5fd',
  violet: '#a78bfa',
  amber: '#fbbf24',
  slate: '#94a3b8',
} as const

export type PanelKit = {
  Box: ElementConstructor<BoxProps>
  Text: ElementConstructor<TextProps>
  Button: ElementConstructor<ButtonProps>
}

export type PanelInput = {
  groups: readonly SessionGroup[]
  activity: Readonly<Record<string, HudActivity>>
  now: number
  spinnerFrame: number
  error: string | null
  notice: string | null
  stopArmedFor: string | null
  onOpen: (session: HudSession) => Promise<void>
  onStop: (session: HudSession) => Promise<void>
  onRefresh: () => Promise<void>
  onClose: () => Promise<void>
}

export function drawSessionsPanel(kit: PanelKit, input: PanelInput): RenderElement {
  const { Box, Text, Button } = kit

  return (
    <Box flexDirection="column">
      <Box flexDirection="row">
        <Box flexGrow={1}>
          <Text bold color={COLORS.lavender}>
            Sessions
          </Text>
        </Box>
        <Button key="hud-panel-refresh" plain dimColor label="↻" onPress={input.onRefresh} />
        <Text> </Text>
        <Button key="hud-panel-close" plain dimColor label="✕" onPress={input.onClose} />
      </Box>
      {input.error !== null && (
        <Text color={COLORS.amber} wrap="wrap">
          {`Couldn't read the session list: ${input.error}`}
        </Text>
      )}
      {input.error === null && input.groups.length === 0 && <Text dimColor>No sessions are running.</Text>}
      {input.groups.map(group => drawGroup(kit, group, input))}
      {input.notice !== null && (
        <Box marginTop={1}>
          <Text color={COLORS.amber} wrap="wrap">
            {input.notice}
          </Text>
        </Box>
      )}
    </Box>
  )
}

function drawGroup(kit: PanelKit, group: SessionGroup, input: PanelInput): RenderElement {
  const { Box, Text } = kit

  return (
    <Box key={`hud-panel-group-${group.name}`} flexDirection="column" marginTop={1}>
      <Text bold>{`${group.name} · ${group.sessions.length}`}</Text>
      {group.sessions.map(session => drawSessionRow(kit, session, input))}
    </Box>
  )
}

function drawSessionRow(kit: PanelKit, session: HudSession, input: PanelInput): RenderElement {
  const { Box, Text, Button } = kit
  const mood = moodOf(session)
  const activity = input.activity[session.sessionId]
  const moodMark = mood === 'idle' ? IDLE_MARK : mood === 'working' ? SPINNER_FRAMES[input.spinnerFrame % SPINNER_FRAMES.length] : '●'
  const moodColor = mood === 'needsYou' ? COLORS.amber : mood === 'working' ? COLORS.violet : COLORS.slate
  const isStopArmed = input.stopArmedFor === session.sessionId
  const canStop = !session.isCurrent && session.isBackground

  return (
    <Box key={`hud-panel-session-${session.sessionId}`} flexDirection="column" paddingLeft={2}>
      <Box flexDirection="row">
        <Text color={session.isCurrent ? COLORS.lavender : moodColor}>{`${session.isCurrent ? '▸' : moodMark} `}</Text>
        <Box flexGrow={1} flexShrink={1}>
          {session.isCurrent ? (
            <Text bold wrap="truncate-end">{`${session.name}  (here)`}</Text>
          ) : (
            <Button key={`hud-panel-open-${session.sessionId}`} plain label={session.name} onPress={() => input.onOpen(session)} />
          )}
        </Box>
        <Text color={moodColor}>{`  ${describeTime(session, activity, input.now)}`}</Text>
        {canStop && (
          <Button
            key={`hud-panel-stop-${session.sessionId}`}
            plain
            dimColor={!isStopArmed}
            label={isStopArmed ? '  stop? ■' : '  ■'}
            onPress={() => input.onStop(session)}
          />
        )}
      </Box>
      <Box paddingLeft={2}>
        <Text dimColor wrap="truncate-end">
          {describeWork(session, activity)}
        </Text>
      </Box>
    </Box>
  )
}
```

- [ ] **Step 4: Wire the panel into `hud.tsx`**

Imports (replace the `./sessions` import):

```ts
import { groupSessions, readActivity, readSessions, sessionsLabel } from './session-list'
import { PANEL_ID, SPINNER_FRAMES, drawSessionsPanel } from './sessions-panel'
```

Constants and state (remove `SESSIONS_MENU_CELLS`, `isSessionsMenuOpen`, `sessionsOffset`, `drawnSessionsListRows`):

```ts
const PANEL_REFRESH_EVERY_MS = 15_000
const PANEL_SYNC_EVERY_MS = 1_000
const ACTIVITY_KEPT_MS = 7 * 24 * 60 * 60 * 1000

const activityValue = atom({ plugin: 'hud', key: 'activity' } as const, {})
const repoRootsValue = atom({ plugin: 'hud', key: 'repoRoots' } as const, {})
const stopArmedFor = atom({ plugin: 'hud', key: 'stopArmedFor' } as const, null)

let panelTimers: { cancel: () => void }[] = []
let isPanelSyncPending = false
let panelSyncedAt = Number.NEGATIVE_INFINITY
```

`closeMenus` only closes the model menu now:

```ts
async function closeMenus($: EngineInterface): Promise<void> {
  await update($, isModelMenuOpen, () => false)
}
```

Delete `scrollSessions`, `startSpinner`, `stopSpinner`, `toggleSessionsMenu`, the old `openSession`, `sessionsMenuColumn`, and the `ui.scroll` hook. `isPartOfOpenMenu` keeps `['hud-model', 'hud-menu-']`; `isAnyMenuOpen` reads only `isModelMenuOpen`.

Panel lifecycle (new functions):

```ts
async function panelFlagPath($: EngineInterface): Promise<string> {
  return `${await hudFolder($)}/panel-open`
}

async function isPanelOpen($: EngineInterface): Promise<boolean> {
  return (await $.ui.panes()).some(pane => pane.id === PANEL_ID)
}

async function toggleSessionsPanel($: EngineInterface): Promise<void> {
  if (await isPanelOpen($)) {
    await closeSessionsPanel($)
    return
  }

  await $.fs.write(await panelFlagPath($), 'open')
  await showSessionsPanel($)
}

async function closeSessionsPanel($: EngineInterface): Promise<void> {
  await forgetPanelOpen($)
  await $.ui.close({ id: PANEL_ID })
}

async function forgetPanelOpen($: EngineInterface): Promise<void> {
  await $.process.run(['rm', '-f', await panelFlagPath($)])
}

async function showSessionsPanel($: EngineInterface): Promise<void> {
  await refreshSessions($)
  const [sessions, activity, repoRoots] = await Promise.all([read($, sessionsValue), read($, activityValue), read($, repoRootsValue)])
  const groupCount = groupSessions(sessions, activity, repoRoots).length
  // The header, two rows per session, a header and a margin per group, and room for a notice.
  const rows = 1 + 2 * sessions.length + 2 * groupCount + 3

  await $.ui.open({ id: PANEL_ID, title: 'Sessions', closeOnEscape: true, rows })
  startPanelTimers($)
}

// The spinner and the durations only move while the panel is open, so a closed panel costs nothing.
function startPanelTimers($: EngineInterface): void {
  stopPanelTimers()
  panelTimers = [
    $.clock.every(SPINNER_EVERY_MS, () => void update($, spinnerFrame, frame => (frame + 1) % SPINNER_FRAMES.length)),
    $.clock.every(PANEL_REFRESH_EVERY_MS, () => void refreshSessions($)),
  ]
}

function stopPanelTimers(): void {
  for (const timer of panelTimers) {
    timer.cancel()
  }

  panelTimers = []
}

// Attaching to a running session raises no event, so the band's drawing is where a session learns it is shown again.
function syncPanelLater($: EngineInterface, now: number): void {
  if (isPanelSyncPending || now - panelSyncedAt < PANEL_SYNC_EVERY_MS) {
    return
  }

  isPanelSyncPending = true
  panelSyncedAt = now
  void $.clock
    .sleep(0)
    .then(() => syncPanelWithFlag($))
    .finally(() => {
      isPanelSyncPending = false
    })
}

async function syncPanelWithFlag($: EngineInterface): Promise<void> {
  const [isWanted, isOpen] = await Promise.all([$.fs.exists(await panelFlagPath($)), isPanelOpen($)])

  if (isWanted && !isOpen) {
    await showSessionsPanel($)
  }

  if (!isWanted && isOpen) {
    await $.ui.close({ id: PANEL_ID })
  }
}
```

`refreshSessions` (replace; it keeps the list logic and adds activity and repository roots):

```ts
async function refreshSessions($: EngineInterface): Promise<void> {
  const [currentSessionId, home] = await Promise.all([$.session.id(), $.env.get('HOME')])
  let listed: { exitCode: number; stdout: string; stderr: string }

  try {
    listed = await $.process.run(['claude', 'agents', '--json'])
  } catch (error) {
    await update($, sessionsError, () => (error instanceof Error ? error.message : String(error)))
    return
  }

  if (listed.exitCode !== 0) {
    const reason = listed.stderr.trim().split('\n')[0] || `exit code ${listed.exitCode}`
    await update($, sessionsError, () => reason)
    return
  }

  const sessions = readSessions(listed.stdout, currentSessionId, home ?? '')
  await update($, sessionsValue, () => sessions)
  await update($, sessionsError, () => null)
  await refreshActivity($, sessions)
  await resolveRepoRoots($, sessions)
}

async function refreshActivity($: EngineInterface, sessions: readonly HudSession[]): Promise<void> {
  const folder = `${await hudFolder($)}/activity`
  const [entries, now] = await Promise.all([$.fs.list(folder).catch(() => []), $.clock.now()])
  const listedFiles = new Set(sessions.map(session => `${session.sessionId}.json`))
  const activity: Record<string, HudActivity> = {}

  for (const entry of entries) {
    const path = `${folder}/${entry.name}`

    if (listedFiles.has(entry.name)) {
      const record = readActivity(await $.fs.read(path).catch(() => ''))

      if (record !== null) {
        activity[record.sessionId] = record
      }
    } else if (now - entry.mtimeMs > ACTIVITY_KEPT_MS) {
      await $.process.run(['rm', '-f', path])
    }
  }

  await update($, activityValue, () => activity)
}

async function resolveRepoRoots($: EngineInterface, sessions: readonly HudSession[]): Promise<void> {
  const [known, activity] = await Promise.all([read($, repoRootsValue), read($, activityValue)])
  const unknownFolders = [
    ...new Set(
      sessions
        .filter(session => session.cwd !== '' && activity[session.sessionId]?.repoRoot == null && !(session.cwd in known))
        .map(session => session.cwd),
    ),
  ]

  if (unknownFolders.length === 0) {
    return
  }

  const found = await Promise.all(unknownFolders.map(async cwd => [cwd, await readRepoRoot($, cwd)] as const))
  await update($, repoRootsValue, roots => ({ ...roots, ...Object.fromEntries(found) }))
}
```

Placeholder actions (Task 6 replaces both bodies):

```ts
async function openSession($: EngineInterface, target: HudSession): Promise<void> {
  await update($, sessionsNotice, () => `Opening "${target.name}" comes in the next step.`)
}

async function stopSession($: EngineInterface, target: HudSession): Promise<void> {
  await update($, sessionsNotice, () => `Stopping "${target.name}" comes in the next step.`)
}
```

Hooks (in `registerHud`):

```ts
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await refreshEverything($)
    await refreshSessions($)
    await syncPanelWithFlag($)
    $.clock.every(REFRESH_EVERY_MS, () => void refreshInBackground($))

    return started
  })

  on('ui.close', async ($, e, next) => {
    if (e.id !== PANEL_ID) {
      return next(e)
    }

    const closed = await next(e)
    stopPanelTimers()

    if (e.origin.kind === 'person') {
      await forgetPanelOpen($)
    }

    return closed
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANEL_ID) {
      return next(e)
    }

    const [sessions, activity, repoRoots, error, notice, frame, armedFor, now] = await Promise.all([
      read($, sessionsValue),
      read($, activityValue),
      read($, repoRootsValue),
      read($, sessionsError),
      read($, sessionsNotice),
      read($, spinnerFrame),
      read($, stopArmedFor),
      $.clock.now(),
    ])
    const { Box, Text, Button } = $.ui.resolve(e)

    return drawSessionsPanel(
      { Box, Text, Button },
      {
        groups: groupSessions(sessions, activity, repoRoots),
        activity,
        now,
        spinnerFrame: frame,
        error,
        notice,
        stopArmedFor: armedFor,
        onOpen: session => openSession($, session),
        onStop: session => stopSession($, session),
        onRefresh: () => refreshSessions($),
        onClose: () => closeSessionsPanel($),
      },
    )
  })
```

In the `AbovePrompt` render hook: delete the `sessionsMenuIsOpen`, `sessionsMenuWidth`, `hudRows`, `notice`, `drawnSessionsListRows` and `sessionsInput` lines and the `hud-sessions-menu` box. Right after `await refreshLaterIfSessionMoved($, snapshot)` add `syncPanelLater($, now)` (move `const now = await $.clock.now()` above it). The button becomes:

```tsx
              <Button key="hud-sessions" hotkey="s" label={sessionsLabel(sessions)} onPress={() => toggleSessionsPanel($)} />
```

Then delete `hooks/sessions.tsx`.

- [ ] **Step 5: Run to verify they pass**

Run: `claude plugin test .`
Expected: all tests pass. If a test of the model menu used `hud-sessions-menu`, update it to only check the model menu.

---

### Task 6: Opening and stopping from the panel

**Files:**
- Modify: `~/.agents/skills/hud/hooks/hud.tsx` (`openSession`, `stopSession` bodies, imports)
- Modify: `~/.agents/skills/hud/tests/hud.test.ts`

**Interfaces:**
- Consumes: `planSwitch`, `terminalCandidates`, `chooseTerminal` (Task 3); atoms and `PANE` test constant (Task 5).

- [ ] **Step 1: Write the failing tests**

```ts
describe('opening and stopping from the panel', () => {
  const ROWS = [
    { id: 'job-this', sessionId: 'session-this', name: 'hud work', cwd: '/work/frontend', kind: 'background', status: 'busy', startedAt: NOW },
    { id: 'job-idle', sessionId: 'session-idle', name: 'order api cleanup', cwd: '/work/order-api', kind: 'background', status: 'idle', startedAt: NOW },
    { sessionId: 'session-own', name: 'own tab', cwd: '/work/frontend', kind: 'interactive', status: 'idle', startedAt: NOW },
  ]
  const PS = '  501 ttys005  /Users/someone/.local/bin/claude agents\n  502 ttys006  /Users/someone/.local/bin/claude attach job-idle\n'
  const ENV = '501 /Users/someone/.local/bin/claude agents CLAUDE_CONFIG_DIR=/Users/someone/.agent-profiles/profiles/designer CLAUDE_PROFILE_SWITCH_FILE=/tmp/switch.77\n'

  function processes(overrides: (argv: readonly string[]) => string | ProcessReply | undefined = () => undefined) {
    return (argv: readonly string[]): string | ProcessReply => {
      const overridden = overrides(argv)
      if (overridden !== undefined) return overridden
      if (argv[0] === 'claude' && argv[1] === 'agents') return JSON.stringify(ROWS)
      if (argv[0] === 'ps' && argv[1] === '-axo') return PS
      if (argv[0] === 'ps' && argv[1] === '-wwE') return ENV
      return defaultProcessStdout(argv)
    }
  }

  async function openPanel($: Engine) {
    await startSession($)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'hud-sessions' })
    return $.ui.mount({ ...PANE, surface: 'terminal' })
  }

  test('a click hands the session to the one terminal showing this one, and ends that display', async ($, on) => {
    const written: Written[] = []
    const ran: string[][] = []
    engineBeneath(on, [], [], written, '', processes(argv => (ran.push([...argv]), undefined)))
    const pane = await openPanel($)

    await pane.press({ key: 'hud-panel-open-session-idle' })

    expect(written).toContainEqual({ path: '/tmp/switch.77', text: 'job-idle' })
    expect(ran).toContainEqual(['ps', '-wwE', '-o', 'pid=,command=', '-p', '501'])
    expect(ran).toContainEqual(['kill', '501'])
  })

  test('two terminals that could show this session give a notice instead of a guess', async ($, on) => {
    const ran: string[][] = []
    const twoInAgentView = '  501 ttys005  /Users/someone/.local/bin/claude agents\n  503 ttys007  /Users/someone/.local/bin/claude agents\n'
    const bothInProfile = `${ENV}503 /Users/someone/.local/bin/claude agents CLAUDE_CONFIG_DIR=/Users/someone/.agent-profiles/profiles/designer CLAUDE_PROFILE_SWITCH_FILE=/tmp/switch.78\n`
    engineBeneath(on, [], [], [], '', processes(argv => {
      ran.push([...argv])
      if (argv[1] === '-axo') return twoInAgentView
      if (argv[1] === '-wwE') return bothInProfile
      return undefined
    }))
    const pane = await openPanel($)

    await pane.press({ key: 'hud-panel-open-session-idle' })

    expect(await pane.find({ type: 'Text', text: 'Couldn\'t tell which terminal shows this session. Press ← on an empty prompt, then pick "order api cleanup".' })).toBeDefined()
    expect(ran.some(argv => argv[0] === 'kill')).toBe(false)
  })

  test('a foreground session hands the session to its own launcher and steps into the background', async ($, on) => {
    const ranCommands: string[] = []
    const written: Written[] = []
    const foregroundRows = ROWS.map(row => (row.sessionId === 'session-this' ? { ...row, id: undefined, kind: 'interactive' } : row))
    engineBeneath(on, ranCommands, [], written, '/tmp/agent-profile-switch.42', processes(argv => (argv[0] === 'claude' && argv[1] === 'agents' ? JSON.stringify(foregroundRows) : undefined)))
    const pane = await openPanel($)

    await pane.press({ key: 'hud-panel-open-session-idle' })

    expect(written).toContainEqual({ path: '/tmp/agent-profile-switch.42', text: 'job-idle' })
    expect(ranCommands).toContain('/background ')
  })

  test('a session in its own terminal cannot be opened and says why', async ($, on) => {
    engineBeneath(on, [], [], [], '', processes())
    const pane = await openPanel($)

    await pane.press({ key: 'hud-panel-open-session-own' })

    expect(await pane.find({ type: 'Text', text: '"own tab" is open in its own terminal, so it can\'t be opened here.' })).toBeDefined()
  })

  test('stop asks once, then stops on the second press', async ($, on) => {
    const ran: string[][] = []
    engineBeneath(on, [], [], [], '', processes(argv => (ran.push([...argv]), undefined)))
    const pane = await openPanel($)

    await pane.press({ key: 'hud-panel-stop-session-idle' })

    expect(await pane.find({ type: 'Button', key: 'hud-panel-stop-session-idle', text: '  stop? ■' })).toBeDefined()
    expect(ran).not.toContainEqual(['claude', 'stop', 'job-idle'])

    await pane.press({ key: 'hud-panel-stop-session-idle' })

    expect(ran).toContainEqual(['claude', 'stop', 'job-idle'])
  })

  test('an unconfirmed stop returns to normal after five seconds', async ($, on) => {
    const ran: string[][] = []
    const clock = engineBeneath(on, [], [], [], '', processes(argv => (ran.push([...argv]), undefined)))
    const pane = await openPanel($)

    await pane.press({ key: 'hud-panel-stop-session-idle' })
    await clock.advance(5_000)

    expect(await pane.find({ type: 'Button', key: 'hud-panel-stop-session-idle', text: '  ■' })).toBeDefined()

    await pane.press({ key: 'hud-panel-stop-session-idle' })

    expect(ran).not.toContainEqual(['claude', 'stop', 'job-idle'])
  })

  test('a failed stop shows the reason', async ($, on) => {
    engineBeneath(on, [], [], [], '', processes(argv =>
      argv[1] === 'stop' ? { exitCode: 1, stdout: '', stderr: 'no such session: job-idle\nmore' } : undefined,
    ))
    const pane = await openPanel($)

    await pane.press({ key: 'hud-panel-stop-session-idle' })
    await pane.press({ key: 'hud-panel-stop-session-idle' })

    expect(await pane.find({ type: 'Text', text: 'Couldn\'t stop "order api cleanup": no such session: job-idle' })).toBeDefined()
  })
})
```

- [ ] **Step 2: Run to verify they fail**

Run: `claude plugin test .`
Expected: FAIL (placeholder notices instead of writes, kills and stops).

- [ ] **Step 3: Implement** (replace the two placeholder bodies; add the import)

```ts
import { chooseTerminal, planSwitch, terminalCandidates } from './session-switch'

const STOP_CONFIRM_MS = 5_000

async function openSession($: EngineInterface, target: HudSession): Promise<void> {
  await update($, sessionsNotice, () => null)
  const [sessions, ownSwitchFile, configDir] = await Promise.all([
    read($, sessionsValue),
    $.env.get('CLAUDE_PROFILE_SWITCH_FILE'),
    $.env.get('CLAUDE_CONFIG_DIR'),
  ])
  const current = sessions.find(session => session.isCurrent)
  const plan = planSwitch(target, current, ownSwitchFile)

  if (plan.route === 'refuse') {
    await update($, sessionsNotice, () => plan.reason)
    return
  }

  if (plan.route === 'self') {
    await $.fs.write(plan.switchFile, target.jobId)
    await $.command.run({ command: 'background', args: '' })
    return
  }

  const processes = await $.process.run(['ps', '-axo', 'pid=,tty=,command='])
  const candidates = current === undefined ? [] : terminalCandidates(processes.stdout, current, sessions)
  const environments =
    candidates.length === 0 ? '' : (await $.process.run(['ps', '-wwE', '-o', 'pid=,command=', '-p', candidates.join(',')])).stdout
  const choice = chooseTerminal(candidates, environments, configDir, target.name)

  if ('reason' in choice) {
    await update($, sessionsNotice, () => choice.reason)
    return
  }

  await $.fs.write(choice.switchFile, target.jobId)
  // Ending the display leaves this session running; the terminal's launcher then attaches the target.
  await $.process.run(['kill', String(choice.pid)])
}

async function stopSession($: EngineInterface, target: HudSession): Promise<void> {
  await update($, sessionsNotice, () => null)

  if ((await read($, stopArmedFor)) !== target.sessionId) {
    await update($, stopArmedFor, () => target.sessionId)
    void $.clock
      .sleep(STOP_CONFIRM_MS)
      .then(() => update($, stopArmedFor, armedFor => (armedFor === target.sessionId ? null : armedFor)))
    return
  }

  await update($, stopArmedFor, () => null)
  const stopped = await $.process.run(['claude', 'stop', target.jobId])

  if (stopped.exitCode !== 0) {
    const reason = stopped.stderr.trim().split('\n')[0] || `exit code ${stopped.exitCode}`
    await update($, sessionsNotice, () => `Couldn't stop "${target.name}": ${reason}`)
  }

  await refreshSessions($)
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `claude plugin test .`
Expected: all tests pass.

---

### Task 7: End-to-end run against the real Claude Code

**Files:**
- Create: `~/.agents/skills/hud/tests/e2e/sessions-panel.sh`

**Interfaces:**
- Consumes: the launcher from Task 1 (as the `claude` shell function of an interactive zsh) and the mod from Tasks 2-6.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Drives the real Claude Code in tmux: a launcher start, the panel, a switch, agent view, a stop.
# Usage: sessions-panel.sh <trusted folder> [columns]. Costs one tiny prompt per run.
set -euo pipefail

work=${1:?a folder you trust, e.g. ~/agent-profiles}
columns=${2:-160}
pane=hud-e2e
claude_bin=$HOME/.local/bin/claude
config_dir=$(zsh -ic '_cp_dir "$(_cp_read_name "$(_cp_store)/active")"' 2>/dev/null | tail -n 1)

fail() { echo "FAIL: $*" >&2; screen >&2; exit 1; }
screen() { tmux capture-pane -p -t "$pane"; }
agents() { CLAUDE_CONFIG_DIR=$config_dir "$claude_bin" agents --json; }
job_of() { agents | python3 -c 'import json,sys; print(next((r.get("id","") for r in json.load(sys.stdin) if r["name"]==sys.argv[1]), ""))' "$1"; }
status_of() { agents | python3 -c 'import json,sys; print(next((r["status"] for r in json.load(sys.stdin) if r["name"]==sys.argv[1]), "gone"))' "$1"; }

wait_for() {
  for _ in $(seq 1 60); do screen | grep -qF -- "$1" && return 0; sleep 0.5; done
  fail "never saw: $1"
}

wait_status() {
  for _ in $(seq 1 120); do [ "$(status_of "$1")" = "$2" ] && return 0; sleep 0.5; done
  fail "$1 never became $2"
}

# A real click: an SGR mouse press and release on the first cell of the text.
click() {
  local row col
  read -r row col < <(screen | awk -v text="$1" '{ i = index($0, text); if (i) { print NR, i; exit } }')
  [ -n "${row:-}" ] || fail "nothing to click: $1"
  tmux send-keys -t "$pane" -l "$(printf '\e[<0;%d;%dM\e[<0;%d;%dm' "$col" "$row" "$col" "$row")"
}

cleanup() {
  for name in e2e-a e2e-b; do
    job=$(job_of "$name"); [ -z "$job" ] || CLAUDE_CONFIG_DIR=$config_dir "$claude_bin" stop "$job" >/dev/null 2>&1 || true
  done
  tmux kill-session -t "$pane" 2>/dev/null || true
}
trap cleanup EXIT

[ -n "$config_dir" ] || fail "could not read the active profile's folder"
zsh -ic "cd '$work' && claude --bg --name e2e-b 'reply with the word ok'" >/dev/null
tmux new-session -d -s "$pane" -x "$columns" -y 45 "zsh -ic \"cd '$work' && claude --name e2e-a\""

wait_for '─ e2e-a ─'
tmux send-keys -t "$pane" 'reply with the word ok' Enter
wait_status e2e-a idle
wait_status e2e-b idle

click 'Sessions ·'
wait_for 'e2e-a  (here)'
wait_for 'e2e-b'
wait_for "$(basename "$work") · 2"
wait_for 'idle'
echo "ok: the panel lists both sessions in one group"

click 'e2e-b'
wait_for 'e2e-b  (here)'
echo "ok: a click opened e2e-b and the panel came back"

tmux send-keys -t "$pane" '/exit' Enter
wait_for 'describe a task for a new session'
tmux send-keys -t "$pane" Enter
wait_for 'e2e-b  (here)'
click 'e2e-a'
wait_for 'e2e-a  (here)'
echo "ok: switching still works after agent view"

row_stop=$(screen | awk '/e2e-b/ && /■/ { print NR; exit }')
[ -n "$row_stop" ] || fail "no stop button on e2e-b"
click_stop() {
  local col
  col=$(screen | awk -v row="$row_stop" 'NR == row { print index($0, "■") }')
  tmux send-keys -t "$pane" -l "$(printf '\e[<0;%d;%dM\e[<0;%d;%dm' "$col" "$row_stop" "$col" "$row_stop")"
}
click_stop
wait_for 'stop? ■'
click_stop
wait_status e2e-b gone
echo "ok: stop with confirm ended e2e-b"

echo "all passed at $columns columns"
```

- [ ] **Step 2: Run it docked and inline**

Run: `bash ~/.agents/skills/hud/tests/e2e/sessions-panel.sh ~/agent-profiles 160 && bash ~/.agents/skills/hud/tests/e2e/sessions-panel.sh ~/agent-profiles 100`
Expected: `all passed at 160 columns` and `all passed at 100 columns`. On a failure the script prints the screen. Fix the cause in the owning task's code, rerun the unit tests, then rerun this.

- [ ] **Step 3: Check the two open points of the spec**

1. **Status while waiting for permission.** In tmux, start `claude --bg --name e2e-perm --permission-mode default 'run the shell command: touch e2e-permission-probe'` (through the launcher in `~/agent-profiles`). Wait 20 seconds, then read `claude agents --json`. If the `status` is not `waiting`, add its value to `STATUS_MOODS` in `session-list.ts` as `needsYou`, with a test in `session-logic.test.ts`. Stop `e2e-perm` and delete `~/agent-profiles/e2e-permission-probe` if it was created.
2. **Session ids.** In the panel run above, the `(here)` mark appeared on the right row. That shows `$.session.id()` matches `claude agents --json` for a launcher session. For a resumed session, start `claude --resume <an earlier session id>` through the launcher, open the panel, and check `(here)` sits on that row.

- [ ] **Step 4: Final full runs**

Run: `cd ~/.agents/skills/hud && ~/.local/bin/claude plugin test . && cd ~/agent-profiles && sh test.sh | tail -1`
Expected: all mod tests pass; `all passed`.
