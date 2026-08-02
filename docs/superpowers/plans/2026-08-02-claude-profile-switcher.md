# claude-profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A sourceable shell wrapper that switches Claude Code between named configuration profiles by swapping `CLAUDE_CONFIG_DIR`, with commands to snapshot, inspect, and share those profiles.

**Architecture:** A profile is a complete `CLAUDE_CONFIG_DIR` under `<store>/profiles/<name>`, built by copying everything from a source config directory except a fixed list of large or runtime paths, which are symlinked back to `~/.claude`. A POSIX-sh function overrides the `claude` command, resolves which profile applies, and execs the real binary with `CLAUDE_CONFIG_DIR` set.

**Tech Stack:** POSIX sh (must run under both zsh and bash). `python3` for JSON reading in `--show` / `--diff` only. `tar` for export/import. No other dependencies, no package manager, no build step.

## Global Constraints

- POSIX sh only. No bash arrays, no `[[ ]]`, no `${(f)}`, no `local` in a form other than plain assignment, no process substitution. The one deliberate exception is the `${BASH_SOURCE:-${(%):-%x}}` self-path idiom in Task 1, which is documented there.
- No username, home directory, or machine-specific path is hardcoded. Everything derives from `$HOME` at runtime.
- Nothing writes to `~/.claude` except `--install-statusline` and `--uninstall-statusline`.
- `--export` never includes `.credentials.json`.
- `--update` and `--delete` move the previous contents to `.backups/<name>-<YYYYmmdd-HHMMSS>/` before destroying anything.
- A missing or unknown profile prints a warning to stderr and falls back to `~/.claude`. It never exits non-zero from the `claude` wrapper path.
- Every test runs against a temporary store and a temporary fake home. No test may read or write the real `~/.claude`.
- Shared-path symlinks always point at `$HOME/.claude/<entry>`, never at the source profile, so profiles never chain through each other.

**Shared list** (symlinked, verbatim — used in Tasks 2, 8, 10):

```
plugins projects history.jsonl .credentials.json context-mode
file-history cache sessions shell-snapshots backups telemetry tasks
paste-cache debug downloads ide chrome session-env
.session-stats.json stats-cache.json claude-devtools-notifications.json
```

**Skip list** (neither copied nor linked): `.DS_Store`

## File Structure

| File | Responsibility |
|---|---|
| `claude-profile.sh` | Everything: the `claude` override, resolution, and all subcommands. Single file because colleagues install it with one `source` line; splitting into `lib/` would trade that for no testability gain, since `test.sh` sources this file and calls internal functions directly. |
| `test.sh` | Test harness plus all assertions. Run with `sh test.sh` and `bash test.sh`. |
| `README.md` | Install, command reference, what is shared vs per-profile, uninstall. |
| `.gitignore` | Already committed: `profiles/`, `active`, `.backups/`, `.DS_Store`. |

Internal function naming: every private function is prefixed `_cp_`. The only public name is the `claude` function itself.

---

### Task 1: Test harness, store resolution, and profile resolution order

**Files:**
- Create: `claude-profile.sh`
- Create: `test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `_cp_store()` → prints the store directory path
  - `_cp_find_pin()` → prints the path of the nearest `.claude-profile` file walking up from `$PWD`, or returns 1
  - `_cp_read_name FILE` → prints the first non-empty, comment-stripped, whitespace-stripped line of FILE
  - `_cp_selected()` → prints the selected profile name (may be empty) and sets `_CP_SRC` to one of `env`, `pin:<path>`, `active`, `none`
  - `_cp_resolve()` → prints the config directory to use; warns to stderr and prints `$HOME/.claude` when the selected profile does not exist

- [ ] **Step 1: Write the failing test**

Create `test.sh`:

```sh
#!/bin/sh
# Test harness for claude-profile.sh
# Runs against a temporary store and a temporary fake home.

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
no()   { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2' want '$3')"; fi; }

HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Fake base config dir, shaped like a real ~/.claude
FAKEHOME="$TMP/home"
mkdir -p "$FAKEHOME/.claude/hooks" "$FAKEHOME/.claude/skills/demo" \
         "$FAKEHOME/.claude/plugins/cache" "$FAKEHOME/.claude/projects"
printf 'echo hook\n' > "$FAKEHOME/.claude/hooks/demo.sh"
printf 'name: demo\n'  > "$FAKEHOME/.claude/skills/demo/SKILL.md"
printf 'base instructions\n' > "$FAKEHOME/.claude/CLAUDE.md"
printf 'secret\n' > "$FAKEHOME/.claude/.credentials.json"
printf 'history\n'  > "$FAKEHOME/.claude/history.jsonl"
cat > "$FAKEHOME/.claude/settings.json" <<JSON
{
  "model": "opus-5",
  "enabledPlugins": { "alpha@m": true, "beta@m": false },
  "statusLine": { "type": "command", "command": "$FAKEHOME/.claude/statusline.sh" },
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$FAKEHOME/.claude/hooks/demo.sh" } ] }
    ]
  },
  "env": { "TOOL": "$FAKEHOME/.local/bin/tool" }
}
JSON
printf 'printf hud\n' > "$FAKEHOME/.claude/statusline.sh"

HOME="$FAKEHOME"
export HOME
CLAUDE_PROFILES_DIR="$TMP/store"
export CLAUDE_PROFILES_DIR
mkdir -p "$CLAUDE_PROFILES_DIR"

. "$HERE/claude-profile.sh"

echo "== Task 1: resolution =="

eq "store honours CLAUDE_PROFILES_DIR" "$(_cp_store)" "$TMP/store"

mkdir -p "$TMP/store/profiles/dev"
printf 'dev\n' > "$TMP/store/active"
eq "active file selects profile" "$(_cp_selected)" "dev"
eq "source is active" "$_CP_SRC" "active"
eq "resolve returns profile dir" "$(_cp_resolve)" "$TMP/store/profiles/dev"

mkdir -p "$TMP/repo/nested/deep"
printf 'fin  # inline comment\n' > "$TMP/repo/.claude-profile"
mkdir -p "$TMP/store/profiles/fin"
# Never call eq inside ( ... ): the subshell discards the fails counter, so a
# broken assertion prints FAIL and the suite still exits 0. Capture in the
# subshell, assert outside it.
got=$(cd "$TMP/repo/nested/deep" && _cp_selected)
eq "pin beats active" "$got" "fin"
got=$(cd "$TMP/repo/nested/deep" && CLAUDE_PROFILE=other _cp_selected)
eq "env beats pin" "$got" "other"

printf 'ghost\n' > "$TMP/store/active"
eq "unknown profile falls back to base" "$(_cp_resolve 2>/dev/null)" "$FAKEHOME/.claude"
check "unknown profile warns on stderr" '[ -n "$(_cp_resolve 2>&1 >/dev/null)" ]'

rm -f "$TMP/store/active"
eq "no active resolves to base" "$(_cp_resolve)" "$FAKEHOME/.claude"
eq "no active has source none" "$_CP_SRC" "none"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL — `claude-profile.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `claude-profile.sh`:

```sh
# claude-profile — switch Claude Code between named configuration profiles.
# Source this from ~/.zshrc or ~/.bashrc. POSIX sh; runs under zsh and bash.

# Path of this file when sourced. $BASH_SOURCE is set under bash; the zsh
# fallback ${(%):-%x} is only ever expanded when it is not, so bash never
# parses it as a value.
_CP_SELF="${BASH_SOURCE:-${(%):-%x}}"
_CP_HOME=$(cd "$(dirname "$_CP_SELF")" && pwd)

_cp_store() {
    if [ -n "${CLAUDE_PROFILES_DIR:-}" ]; then
        printf '%s' "$CLAUDE_PROFILES_DIR"
    else
        printf '%s' "$_CP_HOME"
    fi
}

_cp_read_name() {
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" 2>/dev/null | grep -m1 .
}

_cp_find_pin() {
    _d="$PWD"
    while : ; do
        if [ -f "$_d/.claude-profile" ]; then
            printf '%s' "$_d/.claude-profile"
            return 0
        fi
        [ "$_d" = "/" ] && return 1
        _d=$(dirname "$_d")
    done
}

# Prints the selected profile name (possibly empty). Sets _CP_SRC.
_cp_selected() {
    if [ -n "${CLAUDE_PROFILE:-}" ]; then
        _CP_SRC="env"
        printf '%s' "$CLAUDE_PROFILE"
        return 0
    fi
    _pin=$(_cp_find_pin) && {
        _name=$(_cp_read_name "$_pin")
        if [ -n "$_name" ]; then
            _CP_SRC="pin:$_pin"
            printf '%s' "$_name"
            return 0
        fi
    }
    if [ -f "$(_cp_store)/active" ]; then
        _name=$(_cp_read_name "$(_cp_store)/active")
        if [ -n "$_name" ]; then
            _CP_SRC="active"
            printf '%s' "$_name"
            return 0
        fi
    fi
    _CP_SRC="none"
    return 0
}

# Prints the config directory to use.
_cp_resolve() {
    _sel=$(_cp_selected)
    if [ -z "$_sel" ]; then
        printf '%s' "$HOME/.claude"
        return 0
    fi
    if [ -d "$(_cp_store)/profiles/$_sel" ]; then
        printf '%s' "$(_cp_store)/profiles/$_sel"
    else
        printf 'claude-profile: unknown profile "%s", using ~/.claude\n' "$_sel" >&2
        printf '%s' "$HOME/.claude"
    fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "feat: profile resolution order and test harness"
```

---

### Task 2: Build a profile — copy, symlink, and settings.json path rewrite

**Files:**
- Modify: `claude-profile.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `_cp_store()` from Task 1.
- Produces:
  - `_CP_SHARED` — space-delimited shared list, leading and trailing space included for `case` matching
  - `_cp_rewrite SETTINGS_FILE PROFILE_DIR [SOURCE_DIR]` → rewrites `~/.claude/` prefixes in place; when SOURCE_DIR is given and differs from the base config dir, also rewrites `SOURCE_DIR/` → `PROFILE_DIR/`, which is what makes a profile forked from another profile point at itself. SOURCE_DIR is an explicit parameter, never a global read from the caller.
  - `_cp_build SRC_DIR DEST_DIR` → populates DEST_DIR as a profile

- [ ] **Step 1: Write the failing test**

Append to `test.sh`, immediately before the final `echo` / summary block:

```sh
echo "== Task 2: build =="

_cp_build "$FAKEHOME/.claude" "$TMP/store/profiles/built"
B="$TMP/store/profiles/built"

check "settings.json is a real file"   '[ -f "$B/settings.json" ] && [ ! -L "$B/settings.json" ]'
check "skills copied as real dir"      '[ -d "$B/skills/demo" ] && [ ! -L "$B/skills" ]'
check "CLAUDE.md copied"               '[ -f "$B/CLAUDE.md" ]'
check "hooks copied as real dir"       '[ -d "$B/hooks" ] && [ ! -L "$B/hooks" ]'
check "plugins symlinked"              '[ -L "$B/plugins" ]'
check "projects symlinked"             '[ -L "$B/projects" ]'
check "credentials symlinked"          '[ -L "$B/.credentials.json" ]'
check "history symlinked"              '[ -L "$B/history.jsonl" ]'
eq    "symlink points at base"         "$(readlink "$B/plugins")" "$FAKEHOME/.claude/plugins"

check "hook path rewritten to profile" 'grep -q "$B/hooks/demo.sh" "$B/settings.json"'
check "statusline path rewritten"      'grep -q "$B/statusline.sh" "$B/settings.json"'
check "no base config paths remain"    '! grep -q "$FAKEHOME/.claude/" "$B/settings.json"'
check "non-config abs path preserved"  'grep -q "$FAKEHOME/.local/bin/tool" "$B/settings.json"'
check "settings.json still valid json" 'python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$B/settings.json"'

printf 'x\n' > "$FAKEHOME/.claude/.DS_Store"
_cp_build "$FAKEHOME/.claude" "$TMP/store/profiles/built2"
check "DS_Store skipped" '[ ! -e "$TMP/store/profiles/built2/.DS_Store" ]'

# Building from a profile must still link shared paths to base, not chain.
_cp_build "$B" "$TMP/store/profiles/forked"
eq "fork links to base not source" \
   "$(readlink "$TMP/store/profiles/forked/plugins")" "$FAKEHOME/.claude/plugins"
check "fork rewrote paths to itself" \
   'grep -q "$TMP/store/profiles/forked/hooks/demo.sh" "$TMP/store/profiles/forked/settings.json"'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL with `_cp_build: not found`

- [ ] **Step 3: Write minimal implementation**

Append to `claude-profile.sh`:

```sh
# Leading and trailing spaces are required: matched with case " $x " in *" $b "*
_CP_SHARED=" plugins projects history.jsonl .credentials.json context-mode \
file-history cache sessions shell-snapshots backups telemetry tasks \
paste-cache debug downloads ide chrome session-env \
.session-stats.json stats-cache.json claude-devtools-notifications.json "
_CP_SKIP=" .DS_Store "

_cp_is_shared() { case "$_CP_SHARED" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
_cp_is_skipped(){ case "$_CP_SKIP"   in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Rewrite ~/.claude/ prefixes in a settings.json so a profile uses its own
# hooks, scripts and statusline. Paths outside the config dir are untouched.
_cp_rewrite() {
    _f="$1"; _p="$2"
    [ -f "$_f" ] || return 0
    _t="$_f.tmp.$$"
    sed -e "s#$HOME/\.claude/#$_p/#g" \
        -e "s#\$HOME/\.claude/#$_p/#g" \
        -e "s#~/\.claude/#$_p/#g" \
        "$_f" > "$_t" && mv "$_t" "$_f"
}

# Populate $2 as a profile built from config dir $1.
_cp_build() {
    _src="$1"; _dest="$2"
    mkdir -p "$_dest"
    for _e in "$_src"/* "$_src"/.[!.]*; do
        [ -e "$_e" ] || continue
        _b="${_e##*/}"
        _cp_is_skipped "$_b" && continue
        if _cp_is_shared "$_b"; then
            rm -rf "$_dest/$_b"
            [ -e "$HOME/.claude/$_b" ] && ln -s "$HOME/.claude/$_b" "$_dest/$_b"
        else
            rm -rf "$_dest/$_b"
            cp -R "$_e" "$_dest/$_b"
        fi
    done
    _cp_rewrite "$_dest/settings.json" "$_dest"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "feat: build profiles with shared symlinks and path rewriting"
```

---

### Task 3: `create`, `list`, `set active`, `default`, and the `claude` wrapper

**Files:**
- Modify: `claude-profile.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `_cp_build`, `_cp_resolve`, `_cp_selected`, `_cp_store`.
- Produces:
  - `_cp_cmd_create NAME` → creates `<store>/profiles/NAME` from the resolved config dir; returns 1 if it exists
  - `_cp_cmd_set NAME` → writes `<store>/active`; returns 1 if the profile does not exist
  - `_cp_cmd_default` → removes `<store>/active`
  - `_cp_cmd_status` → prints active profile, its source, and the profile list
  - `_cp_main ARGS...` → argument dispatcher
  - `claude()` → the shell function override

- [ ] **Step 1: Write the failing test**

Append to `test.sh` before the summary block:

```sh
echo "== Task 3: create and activate =="

rm -rf "$TMP/store/profiles" "$TMP/store/active"
mkdir -p "$TMP/store/profiles"

_cp_main --create dev >/dev/null
check "create makes profile dir"  '[ -d "$TMP/store/profiles/dev" ]'
check "create built settings"     '[ -f "$TMP/store/profiles/dev/settings.json" ]'
check "create is not active yet"  '[ ! -f "$TMP/store/active" ]'

_cp_main --create dev >/dev/null 2>&1
eq "create refuses duplicate" "$?" "1"

_cp_main dev >/dev/null
eq "set writes active"   "$(cat "$TMP/store/active")" "dev"
eq "resolve follows it"  "$(_cp_resolve)" "$TMP/store/profiles/dev"

# Creating while a profile is active forks from that profile.
printf 'dev only\n' > "$TMP/store/profiles/dev/MARKER.md"
_cp_main --create fin >/dev/null
check "create forks from active" '[ -f "$TMP/store/profiles/fin/MARKER.md" ]'

_cp_main default >/dev/null
check "default clears active" '[ ! -f "$TMP/store/active" ]'
eq    "default falls back"    "$(_cp_resolve)" "$FAKEHOME/.claude"

_cp_main --reset >/dev/null
check "--reset is an alias for default" '[ ! -f "$TMP/store/active" ]'

_cp_main unknown-name >/dev/null 2>&1
eq "set refuses unknown profile" "$?" "1"
check "refused set left active alone" '[ ! -f "$TMP/store/active" ]'

check "status lists profiles" '_cp_main | grep -q dev'
_cp_main dev >/dev/null
check "status names active"   '_cp_main | grep -q "active: dev"'
check "status names source"   '_cp_main | grep -q "active"'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL with `_cp_main: not found`

- [ ] **Step 3: Write minimal implementation**

Append to `claude-profile.sh`:

```sh
_cp_dir()    { printf '%s' "$(_cp_store)/profiles/$1"; }
_cp_exists() { [ -d "$(_cp_dir "$1")" ]; }
_cp_valid_name() {
    case "$1" in
        ""|.|..|*/*|-*) return 1 ;;
        *) return 0 ;;
    esac
}

_cp_cmd_create() {
    _n="$1"
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    if _cp_exists "$_n"; then
        printf 'claude-profile: profile "%s" already exists\n' "$_n" >&2
        return 1
    fi
    _from=$(_cp_resolve) || return 1
    mkdir -p "$(_cp_store)/profiles"
    _cp_build "$_from" "$(_cp_dir "$_n")"
    printf 'created %s <- %s\n' "$_n" "$_from"
}

_cp_cmd_set() {
    _n="$1"
    if ! _cp_exists "$_n"; then
        printf 'claude-profile: no such profile "%s"\n' "$_n" >&2
        return 1
    fi
    # Guard the write: an unwritable store must not report success. Without
    # this the user believes they switched and the next claude silently runs
    # base config.
    if ! printf '%s\n' "$_n" > "$(_cp_store)/active"; then
        printf 'claude-profile: could not write %s/active\n' "$(_cp_store)" >&2
        return 1
    fi
    printf 'active profile: %s\n' "$_n"
}

_cp_cmd_default() {
    rm -f "$(_cp_store)/active"
    if [ -e "$(_cp_store)/active" ]; then
        printf 'claude-profile: could not remove %s/active\n' "$(_cp_store)" >&2
        return 1
    fi
    printf 'active profile: none (using ~/.claude)\n'
}

_cp_cmd_status() {
    _sel=$(_cp_selected)
    if [ -z "$_sel" ]; then
        printf 'active: none (using ~/.claude)\n'
    else
        printf 'active: %s  (%s)\n' "$_sel" "$_CP_SRC"
    fi
    printf 'profiles:\n'
    if [ -d "$(_cp_store)/profiles" ]; then
        for _p in "$(_cp_store)"/profiles/*; do
            [ -d "$_p" ] || continue
            printf '  %s\n' "${_p##*/}"
        done
    fi
}

_cp_main() {
    case "${1:-}" in
        "")                 _cp_cmd_status ;;
        default|--reset)    _cp_cmd_default ;;
        --create)           shift; _cp_cmd_create "$@" ;;
        -h|--help)          _cp_cmd_status ;;
        -*)                 printf 'claude-profile: unknown option %s\n' "$1" >&2; return 1 ;;
        *)                  _cp_cmd_set "$1" ;;
    esac
}

claude() {
    if [ "${1:-}" = profile ]; then
        shift
        _cp_main "$@"
        return $?
    fi
    CLAUDE_CONFIG_DIR="$(_cp_resolve)" command claude "$@"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "feat: create, activate and list profiles"
```

---

### Task 4: One-shot run — `claude profile <name> -- <args>`

**Files:**
- Modify: `claude-profile.sh:_cp_main`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `_cp_dir`, `_cp_exists` from Task 3.
- Produces: `_cp_cmd_run NAME ARGS...` → runs `command claude ARGS...` with `CLAUDE_CONFIG_DIR` set to NAME's directory, leaving `active` untouched. Exposes `_CP_RUNNER` (default `command claude`) purely so tests can substitute a stub.

- [ ] **Step 1: Write the failing test**

First add this stub to `test.sh`, on the line immediately after `. "$HERE/claude-profile.sh"`:

```sh
_cp_test_runner() { printf 'CFG=%s ARGS=%s\n' "$CLAUDE_CONFIG_DIR" "$*"; }
```

Then append to `test.sh` before the summary block:

```sh
echo "== Task 4: one-shot run =="

_cp_main dev >/dev/null

out=$(_CP_RUNNER='_cp_test_runner' _cp_main fin -- --version 2>&1)
eq "one-shot used fin dir" "$out" "CFG=$TMP/store/profiles/fin ARGS=--version"
eq "active unchanged after one-shot" "$(cat "$TMP/store/active")" "dev"

out=$(_CP_RUNNER='_cp_test_runner' _cp_main ghost -- --version 2>&1)
check "one-shot on unknown profile errors" 'printf "%s" "$out" | grep -q "no such profile"'
unset _CP_RUNNER
```

The trailing `unset` matters: in POSIX sh, a variable assignment prefixing a
*function* call may persist after the call returns, so leaving it set would leak
the stub into later tasks' assertions.

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL — `one-shot used fin dir (got '' want 'CFG=...')`

- [ ] **Step 3: Write minimal implementation**

In `claude-profile.sh`, add above `_cp_main`:

```sh
_CP_RUNNER=${_CP_RUNNER:-}

_cp_run_claude() {
    if [ -n "$_CP_RUNNER" ]; then
        "$_CP_RUNNER" "$@"
    else
        command claude "$@"
    fi
}

_cp_cmd_run() {
    _n="$1"; shift
    if ! _cp_exists "$_n"; then
        printf 'claude-profile: no such profile "%s"\n' "$_n" >&2
        return 1
    fi
    CLAUDE_CONFIG_DIR="$(_cp_dir "$_n")" _cp_run_claude "$@"
}
```

Then replace the `*)` branch of `_cp_main` with:

```sh
        *)
            _n="$1"; shift
            if [ "${1:-}" = "--" ]; then
                shift
                _cp_cmd_run "$_n" "$@"
            else
                _cp_cmd_set "$_n"
            fi
            ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "feat: one-shot profile runs that leave the active profile alone"
```

---

### Task 5: `--update` with mirror semantics and a backup

**Files:**
- Modify: `claude-profile.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `_cp_build`, `_cp_resolve`, `_cp_dir`, `_cp_exists`.
- Produces:
  - `_cp_backup NAME` → moves `<store>/profiles/NAME` to `<store>/.backups/NAME-<YYYYmmdd-HHMMSS>` and prints the backup path
  - `_cp_cmd_update NAME` → backs up, then rebuilds NAME from the resolved config dir; refuses when NAME is the resolved source

- [ ] **Step 1: Write the failing test**

Append to `test.sh` before the summary block:

```sh
echo "== Task 5: update =="

_cp_main default >/dev/null
printf 'tuned by hand\n' > "$TMP/store/profiles/fin/LOCAL.md"
rm -f "$TMP/store/profiles/fin/CLAUDE.md"

_cp_main --update fin >/dev/null
check "update restored file from source" '[ -f "$TMP/store/profiles/fin/CLAUDE.md" ]'
check "update removed profile-only file" '[ ! -f "$TMP/store/profiles/fin/LOCAL.md" ]'
check "update made a backup"             'ls -d "$TMP/store/.backups/fin-"* >/dev/null 2>&1'
check "backup kept the removed file"     'cat "$TMP/store/.backups/fin-"*/LOCAL.md >/dev/null 2>&1'
check "update relinked shared paths"     '[ -L "$TMP/store/profiles/fin/plugins" ]'
check "update rewrote settings paths"    'grep -q "$TMP/store/profiles/fin/hooks/demo.sh" "$TMP/store/profiles/fin/settings.json"'

_cp_main --update ghost >/dev/null 2>&1
eq "update refuses unknown profile" "$?" "1"

_cp_main fin >/dev/null
_cp_main --update fin >/dev/null 2>&1
eq "update refuses self as source" "$?" "1"
check "self-update left profile intact" '[ -f "$TMP/store/profiles/fin/settings.json" ]'
_cp_main default >/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL — `update restored file from source`, and `_cp_main: unknown option --update`

- [ ] **Step 3: Write minimal implementation**

Append to `claude-profile.sh`:

```sh
# Returns non-zero if the backup could not be made. Callers MUST abort on
# failure: the backup is this tool's only rollback, so reporting success for a
# backup that does not exist, right before overwriting the profile it was meant
# to protect, is the worst failure the tool has.
_cp_backup() {
    _n="$1"
    _stamp=$(date +%Y%m%d-%H%M%S)
    _dst="$(_cp_store)/.backups/$_n-$_stamp"
    mkdir -p "$(_cp_store)/.backups" || return 1
    mv "$(_cp_dir "$_n")" "$_dst" || return 1
    printf '%s' "$_dst"
}

_cp_cmd_update() {
    _n="$1"
    if ! _cp_exists "$_n"; then
        printf 'claude-profile: no such profile "%s"\n' "$_n" >&2
        return 1
    fi
    _from=$(_cp_resolve)
    if [ "$_from" = "$(_cp_dir "$_n")" ]; then
        printf 'claude-profile: "%s" is the active source; switch away first\n' "$_n" >&2
        return 1
    fi
    if ! _bk=$(_cp_backup "$_n"); then
        printf 'claude-profile: backup failed, not updating "%s"\n' "$_n" >&2
        return 1
    fi
    _cp_build "$_from" "$(_cp_dir "$_n")"
    printf 'backed up -> %s\n' "$_bk"
    printf 'updated %s <- %s\n' "$_n" "$_from"
}
```

Add to the `case` in `_cp_main`, after the `--create` line:

```sh
        --update)           shift; _cp_cmd_update "$@" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "feat: update profiles with mirror semantics and backups"
```

---

### Task 5b: Propagate failures out of `_cp_build` and `_cp_rewrite`

Added mid-execution after review of Task 5. Not speculative hardening: the
reviewer forced a permission-denied on one file mid-`cp -R` against the
then-current code and got exit 0, `updated fin <- …`, and a profile with an
empty `skills/b`. The backup succeeded, the rebuild half-failed, and the tool
reported success.

`_cp_build` and `_cp_rewrite` are the primitives every profile-writing command
routes through. Task 6 adds `--copy` as a third caller and Task 8 adds
`--import` as a fourth. Fixing the primitives once is smaller than retrofitting
four call sites, which is why this lands before Task 6 rather than after.

**Files:**
- Modify: `claude-profile.sh` (`_cp_rewrite`, `_cp_build`, `_cp_cmd_create`, `_cp_cmd_update`)
- Modify: `test.sh`

**Interfaces:**
- Consumes: everything from Tasks 2, 3, 5.
- Produces: no new functions. `_cp_rewrite` and `_cp_build` return non-zero on any failed step; `_cp_cmd_create` and `_cp_cmd_update` abort and report failure instead of printing success.

- [ ] **Step 1: Write the failing test**

Append to `test.sh` before the summary block, inside a non-root guard:

```sh
echo "== Task 5b: failure propagation =="

if [ "$(id -u)" -eq 0 ]; then
    printf '  skip failure-propagation tests (running as root)\n'
else
    # A copy that cannot complete must fail the build, not report success.
    _cp_main --create propsrc >/dev/null
    mkdir -p "$FAKEHOME/.claude/skills/locked"
    printf 'x\n' > "$FAKEHOME/.claude/skills/locked/SKILL.md"
    chmod 000 "$FAKEHOME/.claude/skills/locked/SKILL.md"

    _cp_build "$FAKEHOME/.claude" "$TMP/store/profiles/halfbuilt" 2>/dev/null
    eq "build fails when a copy fails" "$?" "1"

    out=$(_cp_main --create halfcreate 2>&1)
    eq "create fails when build fails" "$?" "1"
    check "create reports no success" '! printf "%s" "$out" | grep -q "^created"'

    chmod 644 "$FAKEHOME/.claude/skills/locked/SKILL.md"
    rm -rf "$FAKEHOME/.claude/skills/locked" \
           "$TMP/store/profiles/halfbuilt" "$TMP/store/profiles/halfcreate"
    _CP_YES=1 _cp_main --delete propsrc >/dev/null 2>&1 || rm -rf "$TMP/store/profiles/propsrc"

    # An unwritable settings.json must fail the rewrite.
    mkdir -p "$TMP/rwtest"
    printf '{"a":"%s/.claude/hooks/h.sh"}\n' "$FAKEHOME" > "$TMP/rwtest/settings.json"
    chmod 555 "$TMP/rwtest"
    _cp_rewrite "$TMP/rwtest/settings.json" "$TMP/store/profiles/dev" 2>/dev/null
    eq "rewrite fails when it cannot write" "$?" "1"
    chmod 755 "$TMP/rwtest"
    rm -rf "$TMP/rwtest"
fi

check "no temp files left behind" '[ -z "$(find "$TMP/store/profiles" -name "*.tmp.*" 2>/dev/null)" ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL on `build fails when a copy fails` (got 0, want 1) and `create fails when build fails`.

- [ ] **Step 3: Write minimal implementation**

Replace `_cp_rewrite` and `_cp_build` with guarded versions:

```sh
_cp_rewrite() {
    _f="$1"; _p="$2"; _rsrc="${3:-}"
    [ -f "$_f" ] || return 0
    _t="$_f.tmp.$$"
    if ! sed -e "s#$HOME/\.claude/#$_p/#g" \
             -e "s#\$HOME/\.claude/#$_p/#g" \
             -e "s#~/\.claude/#$_p/#g" \
             "$_f" > "$_t"; then
        rm -f "$_t"
        return 1
    fi
    mv "$_t" "$_f" || { rm -f "$_t"; return 1; }
    if [ -n "$_rsrc" ]; then
        if ! sed -e "s#$_rsrc/#$_p/#g" "$_f" > "$_t"; then
            rm -f "$_t"
            return 1
        fi
        mv "$_t" "$_f" || { rm -f "$_t"; return 1; }
    fi
    return 0
}

_cp_build() {
    _src="$1"; _dest="$2"
    mkdir -p "$_dest" || return 1
    for _e in "$_src"/* "$_src"/.[!.]*; do
        [ -e "$_e" ] || continue
        _b="${_e##*/}"
        _cp_is_skipped "$_b" && continue
        rm -rf "$_dest/$_b" || return 1
        if _cp_is_shared "$_b"; then
            # Explicit if, not `[ -e ] && ln -s`: as the last statement of a
            # branch, a false test would become the function's exit status.
            if [ -e "$HOME/.claude/$_b" ]; then
                ln -s "$HOME/.claude/$_b" "$_dest/$_b" || return 1
            fi
        else
            cp -R "$_e" "$_dest/$_b" || return 1
        fi
    done
    _cp_rewrite "$_dest/settings.json" "$_dest" "$_src" || return 1
    return 0
}
```

Then guard both callers. In `_cp_cmd_create`, replace the unchecked build and
unconditional success message:

```sh
    if ! _cp_build "$_from" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: failed to build "%s"\n' "$_n" >&2
        rm -rf "$(_cp_dir "$_n")"
        return 1
    fi
    printf 'created %s <- %s\n' "$_n" "$_from"
```

Removing the partial directory matters: a half-built profile left on disk is
selectable by name and loads as a broken config. `create` is the only command
that may remove one, because it is the only one where the directory did not
exist beforehand.

In `_cp_cmd_update`, the profile's previous contents are already safe in the
backup, so report the failure and point at it rather than deleting anything:

```sh
    if ! _cp_build "$_from" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: failed to rebuild "%s"; previous contents are at %s\n' "$_n" "$_bk" >&2
        return 1
    fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`, all prior assertions still green.

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "fix: propagate failures out of profile build and rewrite"
```

---

### Task 5c: Stop `_cp_backup` from nesting on a same-second collision

Added after Task 9 review. The plan originally accepted same-second timestamp
collisions in `_cp_backup` as a known limitation. That was written assuming a
collision would overwrite or error. It does neither: `mv` into an existing
directory *nests* inside it.

Reproduced: `--update dev` then `--delete dev` within the same second both
resolve to `.backups/dev-<TS>`. The first moves the profile there. The second
lands at `.backups/dev-<TS>/dev/`. Both return 0 and both print the same path.
Anyone restoring from the reported path gets the first generation; the second is
buried a directory deeper with nothing pointing at it.

The identical fix already shipped in `_cp_backup_statusline` (Task 9): search for
a free name instead of trusting the timestamp.

**Files:**
- Modify: `claude-profile.sh` (`_cp_backup`)
- Modify: `test.sh`

**Interfaces:**
- Consumes: `_cp_store`, `_cp_dir`.
- Produces: no signature change. `_cp_backup` never writes into an existing path.

- [ ] **Step 1: Write the failing test**

Append to `test.sh` before the summary block:

```sh
echo "== Task 5c: backup collision =="

_cp_main --create colla >/dev/null
printf 'gen1\n' > "$TMP/store/profiles/colla/GEN.md"

# Force both backups into the same timestamp.
date() { printf '20260101-000000\n'; }

bk1=$(_cp_backup colla)
_cp_main --create colla >/dev/null
printf 'gen2\n' > "$TMP/store/profiles/colla/GEN.md"
bk2=$(_cp_backup colla)

unset -f date

check "collision produced two distinct paths" '[ "$bk1" != "$bk2" ]'
check "first backup holds gen1"  'grep -q gen1 "$bk1/GEN.md"'
check "second backup holds gen2" 'grep -q gen2 "$bk2/GEN.md"'
check "no nesting inside first backup" '[ ! -d "$bk1/colla" ]'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL on `collision produced two distinct paths` and `no nesting inside first backup`.

- [ ] **Step 3: Write minimal implementation**

```sh
_cp_backup() {
    _n="$1"
    _stamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$(_cp_store)/.backups" || return 1
    # Never write into an existing path: mv into an existing directory nests
    # inside it rather than failing, which would leave two generations stacked
    # with only the first reachable at the reported path.
    _dst="$(_cp_store)/.backups/$_n-$_stamp"
    _i=1
    while [ -e "$_dst" ]; do
        _dst="$(_cp_store)/.backups/$_n-$_stamp-$_i"
        _i=$((_i + 1))
    done
    mv "$(_cp_dir "$_n")" "$_dst" || return 1
    printf '%s' "$_dst"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`.

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "fix: never nest a profile backup on a same-second collision"
```

---

### Task 6: `--delete`, `--rename`, `--copy`

**Files:**
- Modify: `claude-profile.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `_cp_backup`, `_cp_dir`, `_cp_exists`, `_cp_valid_name`, `_cp_selected`.
- Produces:
  - `_cp_cmd_delete NAME` → refuses the active profile; requires the name typed on stdin unless `$_CP_YES` is non-empty; moves to `.backups/`
  - `_cp_cmd_rename OLD NEW`
  - `_cp_cmd_copy SRC NEW` → duplicates the directory, then rewrites `settings.json` for the new path

- [ ] **Step 1: Write the failing test**

Append to `test.sh` before the summary block:

```sh
echo "== Task 6: delete, rename, copy =="

_cp_main --create tmp1 >/dev/null
_CP_YES=1 _cp_main --delete tmp1 >/dev/null
check "delete removes profile"  '[ ! -d "$TMP/store/profiles/tmp1" ]'
check "delete backs up"         'ls -d "$TMP/store/.backups/tmp1-"* >/dev/null 2>&1'

_cp_main --create tmp2 >/dev/null
_cp_main tmp2 >/dev/null
_CP_YES=1 _cp_main --delete tmp2 >/dev/null 2>&1
eq "delete refuses active profile" "$?" "1"
check "active profile survived"    '[ -d "$TMP/store/profiles/tmp2" ]'
_cp_main default >/dev/null

printf 'no\n' | _cp_main --delete tmp2 >/dev/null 2>&1
check "delete without confirmation keeps profile" '[ -d "$TMP/store/profiles/tmp2" ]'

_cp_main --rename tmp2 tmp3 >/dev/null
check "rename moved dir"     '[ -d "$TMP/store/profiles/tmp3" ] && [ ! -d "$TMP/store/profiles/tmp2" ]'
check "rename fixed paths"   'grep -q "$TMP/store/profiles/tmp3/hooks/demo.sh" "$TMP/store/profiles/tmp3/settings.json"'

_cp_main --copy tmp3 tmp4 >/dev/null
check "copy made a new dir"  '[ -d "$TMP/store/profiles/tmp4" ]'
check "copy fixed paths"     'grep -q "$TMP/store/profiles/tmp4/hooks/demo.sh" "$TMP/store/profiles/tmp4/settings.json"'
check "copy kept symlinks"   '[ -L "$TMP/store/profiles/tmp4/plugins" ]'
eq    "copy symlink to base" "$(readlink "$TMP/store/profiles/tmp4/plugins")" "$FAKEHOME/.claude/plugins"

_cp_main --copy tmp3 tmp4 >/dev/null 2>&1
eq "copy refuses existing target" "$?" "1"

_CP_YES=1 _cp_main --delete tmp3 >/dev/null
_CP_YES=1 _cp_main --delete tmp4 >/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL — `_cp_main: unknown option --delete`

- [ ] **Step 3: Write minimal implementation**

Append to `claude-profile.sh`:

```sh
_cp_cmd_delete() {
    _n="$1"
    _cp_exists "$_n" || { printf 'claude-profile: no such profile "%s"\n' "$_n" >&2; return 1; }
    if [ "$(_cp_selected)" = "$_n" ]; then
        printf 'claude-profile: "%s" is active; run "claude profile default" first\n' "$_n" >&2
        return 1
    fi
    if [ -z "${_CP_YES:-}" ]; then
        printf 'delete profile "%s"? type the name to confirm: ' "$_n"
        read -r _answer
        if [ "$_answer" != "$_n" ]; then
            printf 'cancelled\n'
            return 1
        fi
    fi
    if ! _bk=$(_cp_backup "$_n"); then
        printf 'claude-profile: backup failed, not deleting "%s"\n' "$_n" >&2
        return 1
    fi
    printf 'deleted %s (kept at %s)\n' "$_n" "$_bk"
}

_cp_cmd_rename() {
    _o="$1"; _n="$2"
    _cp_exists "$_o" || { printf 'claude-profile: no such profile "%s"\n' "$_o" >&2; return 1; }
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    _cp_exists "$_n" && { printf 'claude-profile: "%s" already exists\n' "$_n" >&2; return 1; }
    if ! mv "$(_cp_dir "$_o")" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: rename failed\n' >&2
        return 1
    fi
    # Third argument is the OLD profile dir: after the mv, settings.json still
    # carries the old profile's paths, and that pass is what retargets them.
    # No cleanup on failure — unlike create and copy, this directory already
    # existed and holds the only copy of that data.
    if ! _cp_rewrite "$(_cp_dir "$_n")/settings.json" "$(_cp_dir "$_n")" "$(_cp_dir "$_o")"; then
        printf 'claude-profile: renamed to "%s" but path rewrite failed; fix settings.json paths manually\n' "$_n" >&2
        return 1
    fi
    if [ "$(_cp_read_name "$(_cp_store)/active" 2>/dev/null)" = "$_o" ]; then
        printf '%s\n' "$_n" > "$(_cp_store)/active"
    fi
    printf 'renamed %s -> %s\n' "$_o" "$_n"
}

_cp_cmd_copy() {
    _s="$1"; _n="$2"
    _cp_exists "$_s" || { printf 'claude-profile: no such profile "%s"\n' "$_s" >&2; return 1; }
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    _cp_exists "$_n" && { printf 'claude-profile: "%s" already exists\n' "$_n" >&2; return 1; }
    if ! _cp_build "$(_cp_dir "$_s")" "$(_cp_dir "$_n")"; then
        printf 'claude-profile: failed to copy "%s"\n' "$_s" >&2
        rm -rf "$(_cp_dir "$_n")"
        return 1
    fi
    printf 'copied %s -> %s\n' "$_s" "$_n"
}
```

Add to the `case` in `_cp_main`:

```sh
        --delete)           shift; _cp_cmd_delete "$@" ;;
        --rename)           shift; _cp_cmd_rename "$@" ;;
        --copy)             shift; _cp_cmd_copy "$@" ;;
```

Note on `_cp_cmd_rename`: `_cp_rewrite`'s first two passes only match `~/.claude/` prefixes, so after a `mv` the settings still carry the *old profile* path. That is what the third argument is for — never call `_cp_rewrite` with two arguments here and rely on a leftover global. `_cp_cmd_copy` reuses `_cp_build`, which passes its own source through and therefore needs no fixup.

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "feat: delete with guards, rename and copy profiles"
```

---

### Task 7: `--show` and `--diff`

**Files:**
- Modify: `claude-profile.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `_cp_dir`, `_cp_exists`.
- Produces:
  - `_cp_summary DIR` → prints four lines: `model <v>`, `plugins <csv>`, `skills <csv>`, `mcp <csv>`, plus `hooks <n>`
  - `_cp_cmd_show NAME`
  - `_cp_cmd_diff A B`

- [ ] **Step 1: Write the failing test**

Append to `test.sh` before the summary block:

```sh
echo "== Task 7: show and diff =="

out=$(_cp_main --show dev)
check "show reports model"          'printf "%s" "$out" | grep -q "model .*opus-5"'
check "show lists enabled plugin"   'printf "%s" "$out" | grep -q "alpha@m"'
check "show omits disabled plugin"  '! printf "%s" "$out" | grep -q "beta@m"'
check "show lists skills"           'printf "%s" "$out" | grep -q "demo"'
check "show counts hooks"           'printf "%s" "$out" | grep -q "hooks .*1"'

python3 - "$TMP/store/profiles/fin/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["model"] = "haiku-4-5"
d["enabledPlugins"] = {"alpha@m": False, "beta@m": True}
json.dump(d, open(p, "w"), indent=2)
PY
rm -rf "$TMP/store/profiles/fin/skills/demo"

out=$(_cp_main --diff dev fin)
check "diff shows both models"  'printf "%s" "$out" | grep -q "opus-5" && printf "%s" "$out" | grep -q "haiku-4-5"'
check "diff shows plugin delta" 'printf "%s" "$out" | grep -q "alpha@m"'

_cp_main --show ghost >/dev/null 2>&1
eq "show refuses unknown profile" "$?" "1"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL — `_cp_main: unknown option --show`

- [ ] **Step 3: Write minimal implementation**

Append to `claude-profile.sh`:

```sh
_cp_summary() {
    _d="$1"
    python3 - "$_d" <<'PY'
import json, os, sys

d = sys.argv[1]

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {}

s = load(os.path.join(d, "settings.json"))

plugins = sorted(k for k, v in (s.get("enabledPlugins") or {}).items() if v)

# settings.json nests hooks as: event -> [matcher-block, ...] -> block["hooks"].
# Counting the matcher-blocks instead of the commands inside them undercounts
# any block holding more than one hook.
hooks = 0
for _blocks in (s.get("hooks") or {}).values():
    if not isinstance(_blocks, list):
        continue
    for _b in _blocks:
        if isinstance(_b, dict):
            hooks += len(_b.get("hooks") or [])

skills_dir = os.path.join(d, "skills")
skills = sorted(
    e for e in os.listdir(skills_dir)
    if not e.startswith(".") and os.path.isdir(os.path.join(skills_dir, e))
) if os.path.isdir(skills_dir) else []

mcp = sorted((load(os.path.join(d, ".claude.json")).get("mcpServers") or {}))

print("  model    %s" % (s.get("model") or "-"))
print("  plugins  %s" % (", ".join(plugins) or "-"))
print("  skills   %s" % (", ".join(skills) or "-"))
print("  hooks    %d" % hooks)
print("  mcp      %s" % (", ".join(mcp) or "-"))
PY
}

_cp_cmd_show() {
    _n="$1"
    _cp_exists "$_n" || { printf 'claude-profile: no such profile "%s"\n' "$_n" >&2; return 1; }
    printf '%s\n' "$_n"
    _cp_summary "$(_cp_dir "$_n")"
}

_cp_cmd_diff() {
    _a="$1"; _b="$2"
    _cp_exists "$_a" || { printf 'claude-profile: no such profile "%s"\n' "$_a" >&2; return 1; }
    _cp_exists "$_b" || { printf 'claude-profile: no such profile "%s"\n' "$_b" >&2; return 1; }
    printf '%s\n' "$_a"
    _cp_summary "$(_cp_dir "$_a")"
    printf '%s\n' "$_b"
    _cp_summary "$(_cp_dir "$_b")"
}
```

Add to the `case` in `_cp_main`:

```sh
        --show)             shift; _cp_cmd_show "$@" ;;
        --diff)             shift; _cp_cmd_diff "$@" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "feat: show and diff profile contents"
```

---

### Task 8: `--export` and `--import`

**Files:**
- Modify: `claude-profile.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: `_cp_build`, `_cp_dir`, `_cp_exists`, `_cp_is_shared`, `_cp_rewrite`, `_cp_valid_name`.
- Produces:
  - `_cp_owned DIR` → prints the newline-separated names in DIR that are not on the shared list
  - `_cp_cmd_export NAME [PATH]` → writes `PATH` (default `./NAME.tar.gz`)
  - `_cp_cmd_import FILE [NAME]` → creates a profile, relinks shared paths, rewrites `settings.json`

- [ ] **Step 1: Write the failing test**

Append to `test.sh` before the summary block:

```sh
echo "== Task 8: export and import =="

_cp_main --export dev "$TMP/dev.tar.gz" >/dev/null
check "export wrote archive" '[ -s "$TMP/dev.tar.gz" ]'
check "archive has settings" 'tar tzf "$TMP/dev.tar.gz" | grep -q "settings.json"'
check "archive has skills"   'tar tzf "$TMP/dev.tar.gz" | grep -q "skills/demo"'
check "archive omits credentials" '! tar tzf "$TMP/dev.tar.gz" | grep -q "credentials"'
check "archive omits plugins"     '! tar tzf "$TMP/dev.tar.gz" | grep -q "^plugins"'
check "archive omits projects"    '! tar tzf "$TMP/dev.tar.gz" | grep -q "^projects"'

_cp_main --import "$TMP/dev.tar.gz" imported >/dev/null
check "import created profile"    '[ -d "$TMP/store/profiles/imported" ]'
check "import relinked plugins"   '[ -L "$TMP/store/profiles/imported/plugins" ]'
check "import relinked creds"     '[ -L "$TMP/store/profiles/imported/.credentials.json" ]'
check "import rewrote paths"      'grep -q "$TMP/store/profiles/imported/hooks/demo.sh" "$TMP/store/profiles/imported/settings.json"'
check "import left no dev paths"  '! grep -q "profiles/dev/" "$TMP/store/profiles/imported/settings.json"'

_cp_main --import "$TMP/dev.tar.gz" imported >/dev/null 2>&1
eq "import refuses existing name" "$?" "1"

# A profile carrying a real credentials file must never be exported.
_cp_main --create leaky >/dev/null
rm -f "$TMP/store/profiles/leaky/.credentials.json"
printf 'token\n' > "$TMP/store/profiles/leaky/.credentials.json"
_cp_main --export leaky "$TMP/leaky.tar.gz" >/dev/null 2>&1
eq "export refuses real credentials file" "$?" "1"
check "no archive written" '[ ! -e "$TMP/leaky.tar.gz" ]'
_CP_YES=1 _cp_main --delete leaky >/dev/null
_CP_YES=1 _cp_main --delete imported >/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL — `_cp_main: unknown option --export`

- [ ] **Step 3: Write minimal implementation**

Append to `claude-profile.sh`:

```sh
_cp_owned() {
    _d="$1"
    for _e in "$_d"/* "$_d"/.[!.]*; do
        [ -e "$_e" ] || continue
        _b="${_e##*/}"
        _cp_is_shared "$_b" && continue
        _cp_is_skipped "$_b" && continue
        printf '%s\n' "$_b"
    done
}

_cp_cmd_export() {
    _n="$1"
    _cp_exists "$_n" || { printf 'claude-profile: no such profile "%s"\n' "$_n" >&2; return 1; }
    _out="${2:-./$_n.tar.gz}"
    _d=$(_cp_dir "$_n")
    if [ -e "$_d/.credentials.json" ] && [ ! -L "$_d/.credentials.json" ]; then
        printf 'claude-profile: refusing to export "%s": .credentials.json is a real file\n' "$_n" >&2
        return 1
    fi
    _tmplist=$(mktemp)
    _cp_owned "$_d" > "$_tmplist"
    ( cd "$_d" && tar czf - -T "$_tmplist" ) > "$_out"
    rm -f "$_tmplist"
    printf 'exported %s -> %s\n' "$_n" "$_out"
}

_cp_cmd_import() {
    _f="$1"
    [ -f "$_f" ] || { printf 'claude-profile: no such file "%s"\n' "$_f" >&2; return 1; }
    _n="${2:-}"
    if [ -z "$_n" ]; then
        _n=$(basename "$_f")
        _n="${_n%.tar.gz}"
        _n="${_n%.tgz}"
    fi
    _cp_valid_name "$_n" || { printf 'claude-profile: bad name "%s"\n' "$_n" >&2; return 1; }
    _cp_exists "$_n" && { printf 'claude-profile: "%s" already exists\n' "$_n" >&2; return 1; }
    _d=$(_cp_dir "$_n")
    mkdir -p "$_d"
    tar xzf "$_f" -C "$_d" || { rm -rf "$_d"; return 1; }
    # Relink every shared path that exists in base.
    for _b in $_CP_SHARED; do
        [ -e "$HOME/.claude/$_b" ] || continue
        rm -rf "$_d/$_b"
        ln -s "$HOME/.claude/$_b" "$_d/$_b"
    done
    # The archive carries the exporting machine's profile paths. Rewrite any
    # absolute path ending in /profiles/<something>/ to this profile, then the
    # ~/.claude/ prefixes as usual.
    if [ -f "$_d/settings.json" ]; then
        _t="$_d/settings.json.tmp.$$"
        sed -e "s#[^\"]*/profiles/[^\"/]*/#$_d/#g" "$_d/settings.json" > "$_t" && mv "$_t" "$_d/settings.json"
        # Two arguments only: the sed above already retargeted the exporting
        # machine's profile paths, and there is no meaningful source dir here.
        _cp_rewrite "$_d/settings.json" "$_d"
    fi
    printf 'imported %s <- %s\n' "$_n" "$_f"
}
```

Add to the `case` in `_cp_main`:

```sh
        --export)           shift; _cp_cmd_export "$@" ;;
        --import)           shift; _cp_cmd_import "$@" ;;
```

Note: `$_CP_SHARED` is intentionally unquoted in the `for` loop so the shell splits it into words.

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "feat: export and import profiles without credentials"
```

---

### Task 9: `--install-statusline` and `--uninstall-statusline`

**Files:**
- Modify: `claude-profile.sh`
- Modify: `test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `_cp_cmd_install_statusline` → backs up `~/.claude/statusline.sh` to `statusline.sh.bak`, creates the file if absent, appends a guarded block exactly once
  - `_cp_cmd_uninstall_statusline` → removes the guarded block

- [ ] **Step 1: Write the failing test**

Append to `test.sh` before the summary block:

```sh
echo "== Task 9: statusline =="

_cp_main --install-statusline >/dev/null
check "statusline backed up"  '[ -f "$FAKEHOME/.claude/statusline.sh.bak" ]'
check "block installed"       'grep -q "CLAUDE_PROFILE_BLOCK start" "$FAKEHOME/.claude/statusline.sh"'
check "original preserved"    'grep -q "printf hud" "$FAKEHOME/.claude/statusline.sh"'

_cp_main --install-statusline >/dev/null
eq "install is idempotent" \
   "$(grep -c 'CLAUDE_PROFILE_BLOCK start' "$FAKEHOME/.claude/statusline.sh")" "1"

out=$(CLAUDE_CONFIG_DIR="$TMP/store/profiles/dev" sh "$FAKEHOME/.claude/statusline.sh")
check "statusline shows profile" 'printf "%s" "$out" | grep -q "\[dev\]"'

out=$(sh "$FAKEHOME/.claude/statusline.sh")
check "statusline silent without profile" '! printf "%s" "$out" | grep -q "\["'

_cp_main --uninstall-statusline >/dev/null
check "block removed"      '! grep -q "CLAUDE_PROFILE_BLOCK" "$FAKEHOME/.claude/statusline.sh"'
check "original still there" 'grep -q "printf hud" "$FAKEHOME/.claude/statusline.sh"'

# A profile created after install inherits the block through the normal copy.
_cp_main --install-statusline >/dev/null
_cp_main --create sl >/dev/null
check "new profile inherits block" 'grep -q "CLAUDE_PROFILE_BLOCK" "$TMP/store/profiles/sl/statusline.sh"'
_CP_YES=1 _cp_main --delete sl >/dev/null
_cp_main --uninstall-statusline >/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL — `_cp_main: unknown option --install-statusline`

- [ ] **Step 3: Write minimal implementation**

Append to `claude-profile.sh`:

```sh
_CP_SL_START="# CLAUDE_PROFILE_BLOCK start"
_CP_SL_END="# CLAUDE_PROFILE_BLOCK end"

_cp_cmd_install_statusline() {
    _f="$HOME/.claude/statusline.sh"
    if [ -f "$_f" ]; then
        if grep -q "$_CP_SL_START" "$_f"; then
            printf 'statusline block already installed\n'
            return 0
        fi
        cp "$_f" "$_f.bak"
        printf 'backed up -> %s.bak\n' "$_f"
    else
        mkdir -p "$HOME/.claude"
        printf '#!/bin/sh\n' > "$_f"
        cp "$_f" "$_f.bak"
    fi
    {
        printf '%s\n' "$_CP_SL_START"
        printf '[ -n "$CLAUDE_CONFIG_DIR" ] && printf '"'"' · [%%s]'"'"' "${CLAUDE_CONFIG_DIR##*/}"\n'
        printf '%s\n' "$_CP_SL_END"
    } >> "$_f"
    chmod +x "$_f"
    printf 'statusline block installed\n'
}

_cp_cmd_uninstall_statusline() {
    _f="$HOME/.claude/statusline.sh"
    [ -f "$_f" ] || { printf 'no statusline.sh\n'; return 0; }
    _t="$_f.tmp.$$"
    sed -e "/$_CP_SL_START/,/$_CP_SL_END/d" "$_f" > "$_t" && mv "$_t" "$_f"
    chmod +x "$_f"
    printf 'statusline block removed\n'
}
```

Add to the `case` in `_cp_main`:

```sh
        --install-statusline)   _cp_cmd_install_statusline ;;
        --uninstall-statusline) _cp_cmd_uninstall_statusline ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`

- [ ] **Step 5: Commit**

```bash
git add claude-profile.sh test.sh
git commit -m "feat: opt-in statusline integration"
```

---

### Task 10: README, help text, and the shell-portability check

**Files:**
- Create: `README.md`
- Modify: `claude-profile.sh` (help text)
- Modify: `test.sh` (portability assertions)

**Interfaces:**
- Consumes: everything.
- Produces: `_cp_cmd_help` → the command reference printed by `claude profile --help`.

- [ ] **Step 1: Write the failing test**

Append to `test.sh` before the summary block:

```sh
echo "== Task 10: portability and help =="

check "sourceable under dash if present" \
  '{ command -v dash >/dev/null 2>&1 && dash -n "$HERE/claude-profile.sh"; } || true'
check "parses under bash"  'bash -n "$HERE/claude-profile.sh"'
check "parses under zsh"   '{ command -v zsh >/dev/null 2>&1 && zsh -n "$HERE/claude-profile.sh"; } || true'
check "no bashisms: no [[" '! grep -q "\[\[" "$HERE/claude-profile.sh"'
check "no bashisms: no arrays" '! grep -qE "^[[:space:]]*[A-Za-z_]+=\(" "$HERE/claude-profile.sh"'
check "no hardcoded home"  '! grep -q "/Users/" "$HERE/claude-profile.sh"'

check "help lists create" '_cp_main --help | grep -q -- "--create"'
check "help lists export" '_cp_main --help | grep -q -- "--export"'
check "README exists"     '[ -f "$HERE/README.md" ]'
check "README warns about profiles being ignored" 'grep -q "gitignore" "$HERE/README.md"'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh`
Expected: FAIL — `help lists create` and `README exists`

- [ ] **Step 3: Write minimal implementation**

In `claude-profile.sh`, replace the `-h|--help)` branch of `_cp_main` with `-h|--help) _cp_cmd_help ;;` and add:

```sh
_cp_cmd_help() {
    cat <<'EOF'
claude profile                       show active profile and list all
claude profile <name>                set the active profile
claude profile default               clear the active profile (alias: --reset)
claude profile <name> -- <args>      run one session in <name>, active unchanged

claude profile --create <name>       snapshot the current setup into a new profile
claude profile --update <name>       mirror the current setup into an existing profile
claude profile --delete <name>       delete a profile (backed up first)
claude profile --rename <a> <b>      rename a profile
claude profile --copy <a> <b>        duplicate a profile

claude profile --show <name>         model, plugins, skills, hooks, mcp servers
claude profile --diff <a> <b>        the same, for two profiles

claude profile --export <name> [f]   write a shareable tarball (no credentials)
claude profile --import <file> [n]   create a profile from a tarball

claude profile --install-statusline    show the active profile in your statusline
claude profile --uninstall-statusline  remove it

Resolution order: $CLAUDE_PROFILE, then .claude-profile walking up from the
current directory, then the active profile, then ~/.claude.
EOF
}
```

Create `README.md`:

````markdown
# claude-profile

Switch Claude Code between named configuration profiles — different enabled
plugins, skills, commands, hooks, MCP servers, model and permissions per
profile — without editing `~/.claude` by hand.

A profile is a complete `CLAUDE_CONFIG_DIR`. Claude Code honours that variable
natively, so switching is just pointing it somewhere else.

## Install

```sh
git clone <this repo> ~/claude-profiles
echo 'source ~/claude-profiles/claude-profile.sh' >> ~/.zshrc   # or ~/.bashrc
exec $SHELL
```

Then snapshot your current setup:

```sh
claude profile --create development
claude profile development
```

`claude` now runs with that profile. `claude profile default` goes back to
plain `~/.claude`.

## Commands

| Command | Does |
|---|---|
| `claude profile` | Active profile, why it was selected, and the full list |
| `claude profile <name>` | Set the active profile |
| `claude profile default` | Clear it. Alias `--reset` |
| `claude profile <name> -- <args>` | One session in `<name>`; active unchanged |
| `claude profile --create <name>` | Snapshot the current setup |
| `claude profile --update <name>` | Mirror the current setup into `<name>` |
| `claude profile --delete <name>` | Delete (moved to `.backups/`) |
| `claude profile --rename <a> <b>` | Rename |
| `claude profile --copy <a> <b>` | Duplicate |
| `claude profile --show <name>` | Model, plugins, skills, hooks, MCP servers |
| `claude profile --diff <a> <b>` | The same, side by side |
| `claude profile --export <name> [file]` | Shareable tarball, never includes credentials |
| `claude profile --import <file> [name]` | Create a profile from a tarball |
| `claude profile --install-statusline` | Show the active profile in your statusline |

## Which profile am I in?

Most specific wins:

1. `CLAUDE_PROFILE=finance claude` — one invocation
2. A `.claude-profile` file containing a profile name, found walking up from
   the current directory
3. The active profile (`claude profile <name>`)
4. `~/.claude`

`claude profile` tells you which of these fired.

## Shared vs per-profile

Per-profile (copied): `settings.json`, `CLAUDE.md`, `skills/`, `commands/`,
`hooks/`, `agents/`, `scripts/`, `statusline.sh`, `.claude.json`.

Shared across all profiles (symlinked back to `~/.claude`): `plugins/` (the
download cache — install once, enable per profile in `settings.json`),
`projects/`, `history.jsonl`, `.credentials.json` (so you never re-authenticate),
and the runtime directories.

## Where the data lives

Profiles live in `profiles/` inside this clone, with the active profile name in
`active` and pre-update snapshots in `.backups/`. **All three are in
`.gitignore` and must stay there** — a `settings.json` can contain environment
variables and API keys. Set `CLAUDE_PROFILES_DIR` to keep them elsewhere.

## Uninstall

Remove the `source` line from your shell rc, run
`claude profile --uninstall-statusline` if you installed it, and delete the
clone. `~/.claude` is untouched throughout — this tool never writes to it,
except for the opt-in statusline block.

## Requirements

POSIX sh (zsh or bash), `tar`, and `python3` for `--show` and `--diff` only.

## Tests

```sh
sh test.sh && bash test.sh
```

Tests run against a temporary store and a temporary fake home. They never read
or write your real `~/.claude`.
````

- [ ] **Step 4: Run test to verify it passes**

Run: `sh test.sh` then `bash test.sh`
Expected: both print `all passed`

- [ ] **Step 5: Commit**

```bash
git add README.md claude-profile.sh test.sh
git commit -m "docs: README and help text; add portability checks"
```

---

### Task 11: Real-world smoke test

**Files:**
- Modify: `README.md` (record the verified result)

This task uses the real `~/.claude`. It creates a profile and reads it back; it
never modifies base config.

- [ ] **Step 1: Source the tool in a fresh shell**

Run: `cd ~/claude-profiles && sh -c 'set -e; . ./claude-profile.sh; _cp_main --create smoke'`
Expected: `created smoke <- /Users/<you>/.claude`

- [ ] **Step 2: Verify the shared symlinks resolve and the copies are real**

Run:
```sh
ls -ld profiles/smoke/plugins profiles/smoke/projects profiles/smoke/.credentials.json
ls -ld profiles/smoke/settings.json profiles/smoke/skills
du -sh profiles/smoke
```
Expected: the first three are symlinks into `~/.claude`; the last two are real; total size under 20 MB.

- [ ] **Step 3: Verify the path rewrite against real settings**

Run: `grep -c "$HOME/.claude/" profiles/smoke/settings.json; grep -c "profiles/smoke/" profiles/smoke/settings.json`
Expected: first count `0`, second count `3` or more.

- [ ] **Step 4: Confirm Claude Code accepts the profile**

Run: `CLAUDE_CONFIG_DIR="$PWD/profiles/smoke" claude --version`
Expected: prints the version with no config errors.

- [ ] **Step 5: Clean up and record**

Run: `sh -c '. ./claude-profile.sh; _CP_YES=1 _cp_main --delete smoke'`
Expected: `deleted smoke (kept at .../.backups/smoke-...)`. Then `rm -rf .backups/smoke-*`.

Add a short "Verified on" line to the README with the Claude Code version tested
(`2.1.220` at time of writing), then commit.

```bash
git add README.md
git commit -m "docs: record smoke test against real config"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Store layout, `CLAUDE_PROFILES_DIR` | 1 |
| Shared/copied split, copy-the-rest | 2 |
| settings.json path rewriting | 2 |
| Resolution order incl. pin walk-up, graceful unknown | 1 |
| POSIX-sh wrapper, `claude` override | 3, 10 |
| `claude profile` / `<name>` / `default` / `--reset` | 3 |
| `--create` forking from active | 3 |
| One-shot `-- args` | 4 |
| `--update` mirror + backup + self-refusal | 5 |
| `--delete` guards, `--rename`, `--copy` | 6 |
| `--show`, `--diff` | 7 |
| `--export` credential exclusion, `--import` relink | 8 |
| Opt-in statusline, idempotent, inherited by new profiles | 9 |
| Safety rule 1 (never write `~/.claude`) | 9 is the only writer; asserted in 10 via `no hardcoded home` and by every other test using a fake `$HOME` |
| Safety rule 7 (no hardcoded paths) | 10 |
| README for colleagues | 10 |
| `.gitignore` | already committed in e0f0b36 |

No gaps.

**Placeholder scan:** Clean. Every step carries the real code to write, and no
step instructs the implementer to write something and then remove it.

**Type consistency:** `_cp_dir`, `_cp_exists`, `_cp_valid_name`, `_cp_build`,
`_cp_rewrite`, `_cp_backup`, `_cp_is_shared`, `_cp_is_skipped`, `_cp_selected`,
`_CP_SRC`, `_CP_SHARED`, `_CP_YES`, `_CP_RUNNER` are each defined once and used
under the same name everywhere after. `_cp_summary` is the only function whose
output format two callers depend on (`--show`, `--diff`), and both print it
verbatim.

**Known sharp edges, deliberately accepted:**

- `_cp_rewrite` uses `#` as the sed delimiter. A `$HOME` containing `#` breaks
  it. Not worth guarding for.
- Every internal variable is global — POSIX sh has no `local`. Hence the `_cp_`
  and `_`-prefixed names; a caller's `$n` or `$d` is not clobbered, but a
  caller's `$_n` would be.
- `_cp_build` iterates `"$_src"/*` and `"$_src"/.[!.]*`, which misses names
  beginning with `..`. Claude Code creates none.
