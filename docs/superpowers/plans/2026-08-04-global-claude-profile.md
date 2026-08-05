# Global claude-profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `claude-profile` work in every shell context, not just interactive ones, and make it installable with `npm i -g claude-profiles` without npm owning PATH or any rc file.

**Architecture:** The store moves out of the clone to `~/.claude-profiles`, with a migration that rewrites the absolute paths profiles baked into their own config. Code installs to a stable `~/.claude-profile/`, which owns two PATH surfaces: a `claude-profile` symlink in `~/.local/bin` (works everywhere) and a `claude` shim reached through a `.zshenv` PATH prepend (works in every zsh). npm's only job is delivery — its postinstall dispatches to the existing installers.

**Tech Stack:** POSIX sh (dash-compatible, shellcheck-clean), PowerShell 5.1-compatible, one small node script for the npm postinstall dispatcher.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-04-global-claude-profile-design.md`. Read it before Task 1.
- POSIX sh only in `.sh` files. No bashisms, no arrays, no `local`, no `sed -i`. `dash -n` must parse every script.
- `shellcheck` must pass. `test.sh:551` already lints `claude-profile.sh install.sh lib/*.sh test.sh` — extend that line when adding scripts.
- Variable prefixes follow the existing convention: functions use a per-function prefix (`_ms_`, `_mr_`, `_rc_`, `_dr_`) so nothing collides in a sourced shell.
- No CR bytes in any shell script. `.gitattributes` pins `*.sh text eol=lf`.
- PowerShell files are ASCII only (see the header of `claude-profile.psm1`).
- Store default is exactly `$HOME/.claude-profiles`. Install dir default is exactly `$HOME/.claude-profile` (singular). These are two different directories; do not conflate them.
- Every new env seam gets a name reserved for tests: `CLAUDE_PROFILE_INSTALL_DIR`, `CP_LINK_DIR`, `CP_ZSHENV`. `CP_RC` already exists.
- Tests never touch the real `$HOME`, the real `~/.zshrc`, or the real `~/.zshenv`.
- Commit after every task.

---

### Task 1: Store defaults to `~/.claude-profiles`

**Files:**
- Modify: `lib/resolve.sh:7-13`
- Modify: `claude-profile.sh` (the comment above `_cp_libdir`, roughly lines 50-60)
- Test: `test.sh` (insert into the `== Task 1: resolution ==` section, after line 69)

**Interfaces:**
- Consumes: nothing.
- Produces: `_cp_store()` prints `$CLAUDE_PROFILES_DIR` if set, else `$HOME/.claude-profiles`. Every later task calls it.

- [ ] **Step 1: Write the failing test**

Insert directly after the existing `eq "store honours CLAUDE_PROFILES_DIR" ...` line in `test.sh`:

```sh
# The store used to default to the clone directory, which npm would wipe on
# upgrade. Assert the new default explicitly; the env override is asserted above.
got=$(unset CLAUDE_PROFILES_DIR; _cp_store)
eq "store defaults under HOME" "$got" "$FAKEHOME/.claude-profiles"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh 2>&1 | grep "store defaults"`
Expected: `FAIL store defaults under HOME (got '<repo path>' want '<tmp>/home/.claude-profiles')`

- [ ] **Step 3: Write minimal implementation**

Replace `_cp_store` in `lib/resolve.sh`:

```sh
_cp_store() {
    if [ -n "${CLAUDE_PROFILES_DIR:-}" ]; then
        printf '%s' "$CLAUDE_PROFILES_DIR"
    else
        printf '%s' "$HOME/.claude-profiles"
    fi
}
```

- [ ] **Step 4: Fix the stale comment**

Read `claude-profile.sh` lines 50-60. The comment above `_cp_libdir` states that `_CP_HOME` is also the default store. That is no longer true — `_CP_HOME` is now only where the code lives. Rewrite that clause to say so, keeping the rest of the comment intact.

- [ ] **Step 5: Run the full suite**

Run: `sh test.sh`
Expected: `all passed`. If other assertions broke, they were relying on the old default — fix the assertion, not the implementation.

- [ ] **Step 6: Commit**

```bash
git add lib/resolve.sh claude-profile.sh test.sh
git commit -m "feat: default the store to ~/.claude-profiles"
```

---

### Task 2: Resolve the real `claude`, skipping our own shim

**Files:**
- Modify: `claude-profile.sh` (`_cp_libdir`, roughly lines 40-50)
- Modify: `lib/resolve.sh` (add `_cp_install_dir`)
- Modify: `lib/commands.sh:63-69` (`_cp_run_claude`)
- Test: `test.sh` (new section at the end, before the final summary block at line 930)

**Interfaces:**
- Consumes: `_cp_store` conventions from Task 1.
- Produces:
  - `_cp_deref <path>` — prints `<path>` with its symlink chain fully resolved.
  - `_cp_install_dir` — prints `$CLAUDE_PROFILE_INSTALL_DIR` if set, else `$HOME/.claude-profile`.
  - `_cp_real_claude` — prints the first `claude` on `$PATH` that does not resolve inside `_cp_install_dir`; returns 1 if there is none.
  - `_cp_run_claude` keeps its existing contract (`_CP_RUNNER` overrides everything).

Why: Task 5 puts a script named `claude` on PATH. `command claude` would then resolve to that script, which calls back into us — an infinite loop.

- [ ] **Step 1: Write the failing test**

Append to `test.sh`, before the final summary:

```sh
echo "== Task 17: real claude discovery =="

# Task 5 puts a script named claude on PATH. `command claude` would resolve to
# it and recurse, so the resolver has to skip anything inside the install dir --
# including a symlink that only points there.
mkdir -p "$TMP/fakeinstall/bin" "$TMP/realbin" "$TMP/earlybin"
printf '#!/bin/sh\nprintf shim\n' > "$TMP/fakeinstall/bin/claude"
printf '#!/bin/sh\nprintf real\n' > "$TMP/realbin/claude"
chmod +x "$TMP/fakeinstall/bin/claude" "$TMP/realbin/claude"
ln -s "$TMP/fakeinstall/bin/claude" "$TMP/earlybin/claude"

got=$(
    CLAUDE_PROFILE_INSTALL_DIR="$TMP/fakeinstall"
    PATH="$TMP/fakeinstall/bin:$TMP/realbin"
    _cp_real_claude
)
eq "resolver skips our own shim" "$got" "$TMP/realbin/claude"

# /usr/bin:/bin stays on PATH here because _cp_deref shells out to readlink and
# dirname, which are not builtins -- without them the symlink is never resolved.
# Neither directory contains a claude, so the assertion still proves the skip.
got=$(
    CLAUDE_PROFILE_INSTALL_DIR="$TMP/fakeinstall"
    PATH="$TMP/earlybin:$TMP/realbin:/usr/bin:/bin"
    _cp_real_claude
)
eq "resolver skips a symlink into the install dir" "$got" "$TMP/realbin/claude"

(
    CLAUDE_PROFILE_INSTALL_DIR="$TMP/fakeinstall"
    PATH="$TMP/fakeinstall/bin"
    _cp_real_claude >/dev/null 2>&1
)
eq "resolver fails when only our shim is on PATH" "$?" "1"

eq "install dir honours its env seam" \
   "$(CLAUDE_PROFILE_INSTALL_DIR=/x/y; _cp_install_dir)" "/x/y"
got=$(unset CLAUDE_PROFILE_INSTALL_DIR; _cp_install_dir)
eq "install dir defaults under HOME" "$got" "$FAKEHOME/.claude-profile"

eq "deref follows a symlink chain" "$(_cp_deref "$TMP/earlybin/claude")" \
   "$TMP/fakeinstall/bin/claude"
eq "deref leaves a real file alone" "$(_cp_deref "$TMP/realbin/claude")" \
   "$TMP/realbin/claude"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh 2>&1 | grep -E "resolver|deref|install dir"`
Expected: every line FAILs — `_cp_real_claude`, `_cp_deref` and `_cp_install_dir` do not exist yet.

- [ ] **Step 3: Extract `_cp_deref` in `claude-profile.sh`**

`_cp_libdir` already walks a symlink chain. Pull that loop out so the resolver can reuse it. Replace the existing `_cp_libdir` with:

```sh
_cp_deref() {
    _dr_p="$1"
    while [ -L "$_dr_p" ]; do
        _dr_t=$(readlink "$_dr_p")
        case "$_dr_t" in
            /*) _dr_p="$_dr_t" ;;
            *)  _dr_p="$(dirname "$_dr_p")/$_dr_t" ;;
        esac
    done
    printf '%s' "$_dr_p"
}

_cp_libdir() { (cd "$(dirname "$(_cp_deref "$1")")" && pwd); }
```

`_cp_deref` must stay in `claude-profile.sh`, not in `lib/`: it runs before `lib/` has been located.

- [ ] **Step 4: Add `_cp_install_dir` to `lib/resolve.sh`**

Put it directly below `_cp_store`:

```sh
_cp_install_dir() {
    printf '%s' "${CLAUDE_PROFILE_INSTALL_DIR:-$HOME/.claude-profile}"
}
```

- [ ] **Step 5: Add `_cp_real_claude` and rewire `_cp_run_claude`**

In `lib/commands.sh`, replace `_cp_run_claude` with:

```sh
# A shim named claude sits ahead of the real binary on PATH once installed, so
# `command claude` would resolve back to us and loop. Walk PATH by hand and skip
# anything that resolves inside the install dir.
_cp_real_claude() {
    _rc_skip=$(_cp_install_dir)
    _rc_ifs=$IFS
    IFS=:
    # shellcheck disable=SC2086 # splitting PATH on colons is the point
    set -- $PATH
    IFS=$_rc_ifs
    for _rc_d in "$@"; do
        [ -n "$_rc_d" ] || _rc_d=.
        [ -f "$_rc_d/claude" ] && [ -x "$_rc_d/claude" ] || continue
        case "$(_cp_deref "$_rc_d/claude")" in
            "$_rc_skip"/*) continue ;;
        esac
        printf '%s' "$_rc_d/claude"
        return 0
    done
    return 1
}

_cp_run_claude() {
    if [ -n "$_CP_RUNNER" ]; then
        "$_CP_RUNNER" "$@"
    else
        _rc_bin=$(_cp_real_claude) || {
            printf 'claude-profile: no claude binary on PATH\n' >&2
            return 127
        }
        "$_rc_bin" "$@"
    fi
}
```

- [ ] **Step 6: Run the tests and shellcheck**

Run: `sh test.sh && shellcheck claude-profile.sh install.sh lib/*.sh test.sh`
Expected: `all passed`, and shellcheck silent.

- [ ] **Step 7: Commit**

```bash
git add claude-profile.sh lib/resolve.sh lib/commands.sh test.sh
git commit -m "feat: resolve the real claude binary, skipping our own shim"
```

---

### Task 3: Store migration with a scoped path rewrite

**Files:**
- Create: `lib/migrate.sh`
- Modify: `claude-profile.sh` (the `for _cp_f in ...` loader list, and `_cp_main`'s option `case`, and `_cp_cmd_help`)
- Test: `test.sh` (new section at the end)

**Interfaces:**
- Consumes: `_cp_store` (Task 1).
- Produces: `_cp_migrate_store <legacy-dir>` — moves store contents into `$(_cp_store)` and rewrites baked-in absolute paths. Reachable as `claude-profile --migrate-store <dir>`. Task 5's installer calls it.

Why the rewrite is scoped: `profiles/*/settings.json` holds absolute paths to hooks and the statusline *inside the store*, so they must move with it. But `.claude.json` and `teams/*/config.json` hold project-history `cwd` keys pointing at the old clone, which still exists and must keep pointing there. A blanket rewrite corrupts those.

- [ ] **Step 1: Write the failing test**

Append to `test.sh`:

```sh
echo "== Task 18: store migration =="

LEG="$TMP/legacy"
NEW="$TMP/newstore"
mkdir -p "$LEG/profiles/dev/hooks" "$LEG/exports"
printf '{ "statusLine": { "command": "%s/profiles/dev/statusline.sh" } }\n' "$LEG" \
    > "$LEG/profiles/dev/settings.json"
printf '#!/bin/sh\n%s/profiles/dev/hooks/inner.sh\n' "$LEG" > "$LEG/profiles/dev/hooks/h.sh"
printf 'printf hud\n' > "$LEG/profiles/dev/statusline.sh"
printf '{ "projects": { "%s": { "n": 1 } } }\n' "$LEG" > "$LEG/profiles/dev/.claude.json"
printf 'dev\n' > "$LEG/active"

out=$(CLAUDE_PROFILES_DIR="$NEW"; _cp_migrate_store "$LEG" 2>&1)
eq "migration succeeds" "$?" "0"
check "migration moved profiles"     '[ -d "$NEW/profiles/dev" ] && [ ! -e "$LEG/profiles" ]'
check "migration moved active"       '[ -f "$NEW/active" ]'
check "migration moved exports"      '[ -d "$NEW/exports" ]'
check "settings.json points at the new store" \
   'grep -q "$NEW/profiles/dev/statusline.sh" "$NEW/profiles/dev/settings.json"'
check "hook script points at the new store" \
   'grep -q "$NEW/profiles/dev/hooks/inner.sh" "$NEW/profiles/dev/hooks/h.sh"'
check ".claude.json still points at the old clone" \
   'grep -q "$LEG" "$NEW/profiles/dev/.claude.json"'
check "the original was backed up" \
   'grep -rq "$LEG/profiles/dev/statusline.sh" "$NEW/.backups"'
check "migration reports what it rewrote" 'echo "$out" | grep -q "settings.json"'

# Second run must refuse rather than merge two stores into one.
(CLAUDE_PROFILES_DIR="$NEW"; _cp_migrate_store "$LEG" >/dev/null 2>&1)
eq "migration refuses a non-empty store" "$?" "1"

(CLAUDE_PROFILES_DIR="$NEW"; _cp_migrate_store "$TMP/nope" >/dev/null 2>&1)
eq "migration refuses a missing source" "$?" "1"

MT="$TMP/emptylegacy"; mkdir -p "$MT"
(CLAUDE_PROFILES_DIR="$TMP/store3"; _cp_migrate_store "$MT" >/dev/null 2>&1)
eq "migration refuses a source with no profiles" "$?" "1"

check "executed --migrate-store is wired up" \
   'env HOME="$FAKEHOME" CLAUDE_PROFILES_DIR="$TMP/store4" "$CPX" --migrate-store 2>&1 |
    grep -q "needs a directory"'
check "help mentions --migrate-store" \
   'env $XENV "$CPX" --help | grep -q -- "--migrate-store"'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh 2>&1 | grep -i migrat`
Expected: FAILs — `_cp_migrate_store` does not exist.

- [ ] **Step 3: Create `lib/migrate.sh`**

```sh
# Moving the store out of the clone. Everything a profile baked into its own
# config as an absolute path has to move with it, or every hook silently stops
# firing.
#
# Sourced by ../claude-profile.sh. Not standalone: no shebang, no set -e.

_CP_MIGRATE_ENTRIES="profiles active exports .backups prompt-state.json"

_cp_migrate_store() {
    _ms_from="$1"
    if [ -z "$_ms_from" ]; then
        printf 'claude-profile: --migrate-store needs a directory\n' >&2
        return 1
    fi
    _ms_from=$(cd "$_ms_from" 2>/dev/null && pwd) || {
        printf 'claude-profile: no such directory "%s"\n' "$1" >&2
        return 1
    }
    _ms_to=$(_cp_store)
    if [ "$_ms_from" = "$_ms_to" ]; then
        printf 'claude-profile: "%s" is already the store\n' "$_ms_from" >&2
        return 1
    fi
    if [ ! -d "$_ms_from/profiles" ]; then
        printf 'claude-profile: "%s" has no profiles/ to migrate\n' "$_ms_from" >&2
        return 1
    fi
    if [ -e "$_ms_to/profiles" ]; then
        printf 'claude-profile: "%s" already has profiles/; refusing to merge\n' "$_ms_to" >&2
        return 1
    fi
    # sed builds the rewrite expression from these paths, so a path containing
    # a delimiter or an escape would silently corrupt the file instead.
    case "$_ms_from$_ms_to" in
        *[\\\&\|]*)
            printf 'claude-profile: paths contain \\, & or |, cannot rewrite safely\n' >&2
            return 1 ;;
    esac
    mkdir -p "$_ms_to" || return 1
    for _ms_e in $_CP_MIGRATE_ENTRIES; do
        [ -e "$_ms_from/$_ms_e" ] || continue
        if ! mv "$_ms_from/$_ms_e" "$_ms_to/$_ms_e"; then
            printf 'claude-profile: could not move %s\n' "$_ms_e" >&2
            return 1
        fi
        printf 'moved %s\n' "$_ms_e"
    done
    _cp_migrate_rewrite "$_ms_from" "$_ms_to" || return 1
    printf 'store is now %s\n' "$_ms_to"
}

# Only the files a profile owns. .claude.json and teams/*/config.json hold
# project history for the old clone directory, which still exists and must keep
# pointing there.
_cp_migrate_rewrite() {
    _mr_from="$1"
    _mr_to="$2"
    _mr_backup="$_mr_to/.backups/migrate-$(date +%Y%m%d-%H%M%S)"
    for _mr_p in "$_mr_to"/profiles/*/settings.json \
                 "$_mr_to"/profiles/*/settings.local.json \
                 "$_mr_to"/profiles/*/statusline.sh \
                 "$_mr_to"/profiles/*/hooks/*; do
        [ -f "$_mr_p" ] || continue
        grep -q "$_mr_from/profiles/" "$_mr_p" 2>/dev/null || continue
        _mr_rel=${_mr_p#"$_mr_to"/}
        if ! mkdir -p "$_mr_backup/$(dirname "$_mr_rel")"; then
            printf 'claude-profile: could not create %s\n' "$_mr_backup" >&2
            return 1
        fi
        cp "$_mr_p" "$_mr_backup/$_mr_rel" || {
            printf 'claude-profile: could not back up %s\n' "$_mr_rel" >&2
            return 1
        }
        _mr_t="$_mr_p.cp-tmp.$$"
        if ! sed "s|$_mr_from/profiles/|$_mr_to/profiles/|g" "$_mr_p" > "$_mr_t"; then
            rm -f "$_mr_t"
            printf 'claude-profile: could not rewrite %s\n' "$_mr_rel" >&2
            return 1
        fi
        if ! mv "$_mr_t" "$_mr_p"; then
            rm -f "$_mr_t"
            printf 'claude-profile: could not replace %s\n' "$_mr_rel" >&2
            return 1
        fi
        printf 'rewrote %s\n' "$_mr_rel"
    done
    printf 'backups in %s\n' "$_mr_backup"
}
```

Note: `mv` preserves the executable bit on hooks because it moves the whole tree before the rewrite, and the rewrite writes through `sed` into a temp file then `mv`s over the original — which drops the mode. Add `chmod --reference` handling? No: `mv` over an existing path replaces it, so re-apply the bit explicitly. Insert directly before `printf 'rewrote %s\n'`:

```sh
        [ -x "$_mr_backup/$_mr_rel" ] && chmod +x "$_mr_p"
```

- [ ] **Step 4: Register the file and the option**

In `claude-profile.sh`, add `migrate` to the loader list:

```sh
for _cp_f in build profile commands manage inspect statusline migrate; do
```

In `_cp_main`'s option `case`, next to the other `--` options:

```sh
        --migrate-store) shift; _cp_migrate_store "$@" ;;
```

In `_cp_cmd_help`, add one line in the same column style as its neighbours:

```
claude profile --migrate-store <dir>   move a store out of an old clone
```

- [ ] **Step 5: Run tests and shellcheck**

Run: `sh test.sh && shellcheck claude-profile.sh install.sh lib/*.sh test.sh && dash -n lib/migrate.sh`
Expected: `all passed`, shellcheck silent, dash silent.

- [ ] **Step 6: Commit**

```bash
git add lib/migrate.sh claude-profile.sh test.sh
git commit -m "feat: add --migrate-store with a scoped path rewrite"
```

---

### Task 4: The `claude` shim and `--run-active`

**Files:**
- Create: `bin/claude`
- Create: `bin/claude-profile` (a symlink to `../claude-profile.sh`)
- Modify: `claude-profile.sh` (`_cp_main` option `case`)
- Test: `test.sh` (new section at the end)

**Interfaces:**
- Consumes: `_cp_resolve`, `_cp_launch` (existing), `_cp_real_claude` (Task 2).
- Produces:
  - `claude-profile --run-active [args...]` — launches claude on the resolved profile, passing args through. This is what the shim calls; it is the executable equivalent of the sourced wrapper's fall-through.
  - `bin/claude` — the surface B shim. Task 5 installs it.
  - `bin/claude-profile` — a symlink, so surface A needs no wrapper script at all. `claude-profile.sh` already matches `*/claude-profile` in its exec-detection `case` and already resolves `lib/` through `readlink`.

- [ ] **Step 1: Write the failing test**

Append to `test.sh`:

```sh
echo "== Task 19: bin shims =="

# _CP_RUNNER is read from the environment, so a real script stands in for the
# claude binary across a subprocess boundary where a shell function cannot.
printf '#!/bin/sh\nprintf "CFG=%%s ARGS=%%s\\n" "$CLAUDE_CONFIG_DIR" "$*"\n' > "$TMP/fakerunner"
chmod +x "$TMP/fakerunner"

env $XENV "$CPX" --create shimprof >/dev/null
printf 'shimprof\n' > "$TMP/xstore/active"

check "bin/claude-profile is a symlink" '[ -L "$HERE/bin/claude-profile" ]'
# Assert the link text, not a dereferenced path: _cp_deref resolves a relative
# link against its own directory, so it returns "<repo>/bin/../claude-profile.sh"
# -- correct, and never string-equal to "<repo>/claude-profile.sh".
eq "bin/claude-profile points at the entry script" \
   "$(readlink "$HERE/bin/claude-profile")" "../claude-profile.sh"
check "symlinked entry still finds lib" \
   'env $XENV "$HERE/bin/claude-profile" | grep -q "^store: "'

out=$(env $XENV _CP_RUNNER="$TMP/fakerunner" "$HERE/bin/claude" --version 2>&1)
check "shim launches the active profile" \
   'echo "$out" | grep -q "CFG=$TMP/xstore/profiles/shimprof ARGS=--version"'

out=$(env $XENV "$HERE/bin/claude" profile 2>&1)
check "shim passes 'profile' through to the wrapper" 'echo "$out" | grep -q "^store: "'

out=$(env $XENV _CP_RUNNER="$TMP/fakerunner" "$CPX" --run-active -p hi 2>&1)
check "--run-active passes args through" \
   'echo "$out" | grep -q "CFG=$TMP/xstore/profiles/shimprof ARGS=-p hi"'

check "shim is executable"      '[ -x "$HERE/bin/claude" ]'
check "shim has no CR bytes"    '! grep -q "$(printf "\r")" "$HERE/bin/claude"'
check_with "shim parses under dash" dash 'dash -n "$HERE/bin/claude"'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh 2>&1 | grep -E "shim|run-active|symlink"`
Expected: FAILs — `bin/` does not exist and `--run-active` is not an option.

- [ ] **Step 3: Create `bin/claude`**

```sh
#!/bin/sh
# Surface B: shells that never read an rc file have no `claude` function, so
# `claude profile dev` would reach the real binary as two arguments. On PATH
# ahead of it, this reproduces what the function does.
#
# ponytail: resolves siblings through $0, so symlinking this file elsewhere
# breaks it. Deref $0 first if that ever needs to work.
set -u

_cp_entry="$(dirname "$0")/../claude-profile.sh"

if [ "${1:-}" = profile ]; then
    shift
    exec "$_cp_entry" "$@"
fi

exec "$_cp_entry" --run-active "$@"
```

- [ ] **Step 4: Create the symlink and make the shim executable**

```bash
mkdir -p bin
ln -s ../claude-profile.sh bin/claude-profile
chmod +x bin/claude
```

- [ ] **Step 5: Add `--run-active`**

In `_cp_main`'s option `case` in `claude-profile.sh`:

```sh
        --run-active) shift; _cp_launch "$(_cp_resolve)" "$@" ;;
```

Leave it out of `_cp_cmd_help`: it exists for `bin/claude`, not for people. Say so in a one-line comment above the case arm.

- [ ] **Step 6: Extend the shellcheck line**

In `test.sh:551`, add `"$HERE/bin/claude"` to the shellcheck argument list.

- [ ] **Step 7: Run tests and shellcheck**

Run: `sh test.sh && shellcheck claude-profile.sh install.sh lib/*.sh test.sh bin/claude`
Expected: `all passed`, shellcheck silent.

- [ ] **Step 8: Commit**

```bash
git add bin claude-profile.sh test.sh
git commit -m "feat: add the claude shim and --run-active"
```

---

### Task 5: install.sh installs to a stable directory and owns both PATH surfaces

**Files:**
- Modify: `install.sh` (throughout)
- Test: `test.sh` (extend the `== Task 16 ==` install block)

**Interfaces:**
- Consumes: `claude-profile --migrate-store` (Task 3), `bin/claude` and `bin/claude-profile` (Task 4).
- Produces: an installed tree at `$CLAUDE_PROFILE_INSTALL_DIR` (default `$HOME/.claude-profile`) containing `claude-profile.sh`, `lib/`, `bin/`, `claude-profile.psm1`; a `claude-profile` symlink in `$CP_LINK_DIR` (default `$HOME/.local/bin`); a guarded PATH prepend in `$CP_ZSHENV` (default `$HOME/.zshenv`); and an rc source line pointing at the installed tree. New flags: `--no-shim`, `--from-npm`.

- [ ] **Step 1: Write the failing test**

Append to the end of the Task 16 block in `test.sh` (after the existing idempotency assertion at line 814):

```sh
# Surface A and surface B both come from the installer, so both are asserted
# here against a throwaway HOME rather than trusted to the docs.
IH="$TMP/ihome-stable"
mkdir -p "$IH"
env HOME="$IH" SHELL=/bin/zsh CP_RC="$IH/.zshrc" CP_ZSHENV="$IH/.zshenv" \
    CP_LINK_DIR="$IH/.local/bin" CLAUDE_PROFILE_INSTALL_DIR="$IH/.claude-profile" \
    sh "$HERE/install.sh" --from-npm >"$TMP/stableout" 2>&1
eq "install --from-npm succeeds" "$?" "0"
check "code landed in the install dir" '[ -f "$IH/.claude-profile/claude-profile.sh" ] &&
                                        [ -d "$IH/.claude-profile/lib" ]'
check "surface A is on PATH"      '[ -L "$IH/.local/bin/claude-profile" ]'
check "surface A actually runs"   'env HOME="$IH" "$IH/.local/bin/claude-profile" --help |
                                   grep -q -- "--create"'
check "shim installed"            '[ -x "$IH/.claude-profile/bin/claude" ]'
check "zshenv prepends the bin dir" \
   'grep -qF "$IH/.claude-profile/bin" "$IH/.zshenv"'
check "zshenv guards against a double prepend" 'grep -q "case \":\$PATH:\"" "$IH/.zshenv"'
check "rc points at the install dir" \
   'grep -qF "$IH/.claude-profile/claude-profile.sh" "$IH/.zshrc"'
check "--from-npm prints the migrate hint" 'grep -q -- "--migrate-store" "$TMP/stableout"'

env HOME="$IH" SHELL=/bin/zsh CP_RC="$IH/.zshrc" CP_ZSHENV="$IH/.zshenv" \
    CP_LINK_DIR="$IH/.local/bin" CLAUDE_PROFILE_INSTALL_DIR="$IH/.claude-profile" \
    sh "$HERE/install.sh" --from-npm >/dev/null 2>&1
eq "install is idempotent in the rc"     "$(grep -c 'claude-profile\.sh' "$IH/.zshrc")" "1"
eq "install is idempotent in the zshenv" "$(grep -c 'claude-profile/bin' "$IH/.zshenv")" "1"

# A clone-pointing line is the state every existing user is in. Rewrite it;
# refusing would leave them broken with no path forward.
IH2="$TMP/ihome-oldline"
mkdir -p "$IH2"
printf 'source %s/claude-profile.sh\n' "$HERE" > "$IH2/.zshrc"
env HOME="$IH2" SHELL=/bin/zsh CP_RC="$IH2/.zshrc" CP_ZSHENV="$IH2/.zshenv" \
    CP_LINK_DIR="$IH2/.local/bin" CLAUDE_PROFILE_INSTALL_DIR="$IH2/.claude-profile" \
    sh "$HERE/install.sh" --from-npm >/dev/null 2>&1
eq "install rewrites a clone-pointing rc line" "$?" "0"
eq "only one source line remains" "$(grep -c 'claude-profile\.sh' "$IH2/.zshrc")" "1"
check "the remaining line points at the install dir" \
   'grep -qF "$IH2/.claude-profile/claude-profile.sh" "$IH2/.zshrc"'

IH3="$TMP/ihome-noshim"
mkdir -p "$IH3"
env HOME="$IH3" SHELL=/bin/zsh CP_RC="$IH3/.zshrc" CP_ZSHENV="$IH3/.zshenv" \
    CP_LINK_DIR="$IH3/.local/bin" CLAUDE_PROFILE_INSTALL_DIR="$IH3/.claude-profile" \
    sh "$HERE/install.sh" --from-npm --no-shim >/dev/null 2>&1
check "--no-shim leaves no shim"   '[ ! -e "$IH3/.claude-profile/bin/claude" ]'
check "--no-shim keeps surface A"  '[ -L "$IH3/.local/bin/claude-profile" ]'
check "--no-shim skips the zshenv" '[ ! -f "$IH3/.zshenv" ] ||
                                    ! grep -q "claude-profile/bin" "$IH3/.zshenv"'

# A clone carrying a store gets it migrated, not silently orphaned.
IH4="$TMP/ihome-migrate"
CLONE="$TMP/oldclone"
mkdir -p "$IH4" "$CLONE/profiles/legacyprof"
cp "$HERE/claude-profile.sh" "$CLONE/"
cp -R "$HERE/lib" "$HERE/bin" "$CLONE/"
printf '{ "x": "%s/profiles/legacyprof/statusline.sh" }\n' "$CLONE" \
    > "$CLONE/profiles/legacyprof/settings.json"
env HOME="$IH4" SHELL=/bin/zsh CP_RC="$IH4/.zshrc" CP_ZSHENV="$IH4/.zshenv" \
    CP_LINK_DIR="$IH4/.local/bin" CLAUDE_PROFILE_INSTALL_DIR="$IH4/.claude-profile" \
    sh "$CLONE/install.sh" --from-npm >/dev/null 2>&1 || true
check "a clone store was migrated" '[ -d "$IH4/.claude-profiles/profiles/legacyprof" ]'
check "migrated settings were rewritten" \
   'grep -q "$IH4/.claude-profiles/profiles/legacyprof/statusline.sh" \
      "$IH4/.claude-profiles/profiles/legacyprof/settings.json"'
```

Note the migrate case needs `install.sh` in the fake clone too — add `cp "$HERE/install.sh" "$CLONE/"` next to the other copies.

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh 2>&1 | grep -E "install dir|surface|zshenv|no-shim|migrated"`
Expected: FAILs across the board.

- [ ] **Step 3: Add the new paths and flags to `install.sh`**

Directly under the existing `SELF_DIR` / `TARGET` / `LINE` block, replace those three lines with:

```sh
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
INSTALL_DIR=${CLAUDE_PROFILE_INSTALL_DIR:-$HOME/.claude-profile}
BIN_DIR="$INSTALL_DIR/bin"
LINK_DIR=${CP_LINK_DIR:-$HOME/.local/bin}
ZSHENV=${CP_ZSHENV:-$HOME/.zshenv}
TARGET="$INSTALL_DIR/claude-profile.sh"
LINE=". \"$TARGET\""
ZSHENV_MARK="# claude-profile PATH - added by install.sh"
```

Add to the argument loop:

```sh
        --no-shim)  no_shim=1;  shift ;;
        --from-npm) from_npm=1; shift ;;
```

and initialise `no_shim=""` and `from_npm=""` next to the existing `rc=""`.

Extend `usage()` with both flags, one line each, matching the existing column style.

The existing preflight checks stay, but now validate the source clone:

```sh
[ -f "$SELF_DIR/claude-profile.sh" ] || die "cannot find $SELF_DIR/claude-profile.sh"
[ -d "$SELF_DIR/lib" ]              || die "cannot find $SELF_DIR/lib - is the clone complete?"
[ -d "$SELF_DIR/bin" ]              || die "cannot find $SELF_DIR/bin - is the clone complete?"
```

- [ ] **Step 4: Add the copy, migrate and link steps**

Add these functions after the existing helpers, and call them in this order right before the rc handling:

```sh
copy_code() {
    [ "$SELF_DIR" = "$INSTALL_DIR" ] && return 0
    mkdir -p "$INSTALL_DIR" || die "could not create $INSTALL_DIR"
    for _item in claude-profile.sh lib bin claude-profile.psm1; do
        [ -e "$SELF_DIR/$_item" ] || continue
        rm -rf "$INSTALL_DIR/$_item"
        # -R, not -r: -R is the POSIX spelling and it copies symlinks as
        # symlinks, which is what bin/claude-profile is.
        cp -R "$SELF_DIR/$_item" "$INSTALL_DIR/$_item" \
            || die "could not copy $_item into $INSTALL_DIR"
    done
    [ -n "$no_shim" ] && rm -f "$BIN_DIR/claude"
    say "installed the code to $INSTALL_DIR"
}

migrate_clone_store() {
    [ "$SELF_DIR" = "$INSTALL_DIR" ] && return 0
    [ -d "$SELF_DIR/profiles" ] || return 0
    say "found a store in $SELF_DIR, moving it out of the clone"
    "$TARGET" --migrate-store "$SELF_DIR" \
        || die "the code is installed but the store was not migrated. Run
     '\"$TARGET\" --migrate-store \"$SELF_DIR\"' by hand to see the error."
}

link_bin() {
    mkdir -p "$LINK_DIR" || die "could not create $LINK_DIR"
    ln -sf "$BIN_DIR/claude-profile" "$LINK_DIR/claude-profile" \
        || die "could not link $LINK_DIR/claude-profile"
    say "linked $LINK_DIR/claude-profile"
}

# .zshenv, not .zshrc: this is the only startup file a non-interactive zsh
# reads, which is the whole reason surface B exists.
add_zshenv_path() {
    [ -n "$no_shim" ] && return 0
    [ "$want_shell" = zsh ] || return 0
    if [ -f "$ZSHENV" ] && grep -qF "$BIN_DIR" "$ZSHENV"; then
        say "PATH line already in $ZSHENV"
        return 0
    fi
    {
        printf '\n%s\n' "$ZSHENV_MARK"
        printf 'case ":$PATH:" in *":%s:"*) ;; *) PATH="%s:$PATH" ;; esac\n' \
               "$BIN_DIR" "$BIN_DIR"
        printf 'export PATH\n'
    } >> "$ZSHENV" || die "could not append to $ZSHENV"
    say "added the PATH line to $ZSHENV"
}
```

Call order, placed after `want_shell` and `rc` have been worked out and before the rc file is edited:

```sh
copy_code
migrate_clone_store
link_bin
add_zshenv_path
```

- [ ] **Step 5: Make the rc handling rewrite instead of refuse**

Replace the `if [ -n "$existing" ]` branch that currently calls `exit 1`:

```sh
existing=$(grep -n 'claude-profile\.sh' "$rc" 2>/dev/null || true)
if [ -n "$existing" ]; then
    if grep -qxF "$LINE" "$rc"; then
        say "already installed in $rc"
    else
        # Every existing user has a line pointing at their clone. Refusing would
        # leave them with no path forward, so repoint it -- and collapse any
        # duplicates to one line while we are here.
        _t="$rc.cp-tmp.$$"
        awk -v line="$LINE" '
            /claude-profile\.sh/ && /^[[:space:]]*(\.|source)[[:space:]]/ {
                if (!done) { print line; done = 1 }
                next
            }
            { print }
        ' "$rc" > "$_t" || { rm -f "$_t"; die "could not rewrite $rc"; }
        if ! grep -qxF "$LINE" "$_t"; then
            rm -f "$_t"
            die "$rc mentions claude-profile.sh in a form this script does not
     recognise as a source line. Fix it by hand, then run this again:

$(printf '%s\n' "$existing" | sed 's/^/         /')"
        fi
        mv "$_t" "$rc" || { rm -f "$_t"; die "could not rewrite $rc"; }
        say "pointed the source line in $rc at $TARGET"
    fi
else
```

The `else` branch that appends the line is unchanged.

- [ ] **Step 6: Honour `--from-npm`**

Wrap the verification block (everything from `verify_bin=""` to the login-shell check) in:

```sh
if [ -n "$from_npm" ]; then
    say "skipping the fresh-shell check: npm runs this without a terminal"
else
    ... existing verification ...
fi
```

and add, just before the closing summary:

```sh
if [ -n "$from_npm" ]; then
    say ""
    say "If you are moving off a git clone, move its store too:"
    say ""
    say "    claude-profile --migrate-store <path-to-old-clone>"
fi
```

- [ ] **Step 7: Run tests and shellcheck**

Run: `sh test.sh && shellcheck claude-profile.sh install.sh lib/*.sh test.sh bin/claude && dash -n install.sh`
Expected: `all passed`. The pre-existing Task 16 assertions must still pass — they now exercise the stable-dir path, which is the point.

- [ ] **Step 8: Commit**

```bash
git add install.sh test.sh
git commit -m "feat: install to a stable dir and own both PATH surfaces"
```

---

### Task 6: `install.sh --uninstall`

**Files:**
- Modify: `install.sh`
- Test: `test.sh` (extend the Task 16 block)

**Interfaces:**
- Consumes: the paths and flag parsing from Task 5.
- Produces: `install.sh --uninstall` reverses an install and leaves the store untouched.

- [ ] **Step 1: Write the failing test**

Append to the Task 16 block:

```sh
IH5="$TMP/ihome-uninstall"
mkdir -p "$IH5"
UENV="HOME=$IH5 SHELL=/bin/zsh CP_RC=$IH5/.zshrc CP_ZSHENV=$IH5/.zshenv"
UENV="$UENV CP_LINK_DIR=$IH5/.local/bin CLAUDE_PROFILE_INSTALL_DIR=$IH5/.claude-profile"
env $UENV sh "$HERE/install.sh" --from-npm >/dev/null 2>&1
mkdir -p "$IH5/.claude-profiles/profiles/keepme"

env $UENV sh "$HERE/install.sh" --uninstall >"$TMP/uninstout" 2>&1
eq "uninstall succeeds" "$?" "0"
check "install dir removed"   '[ ! -e "$IH5/.claude-profile" ]'
check "symlink removed"       '[ ! -e "$IH5/.local/bin/claude-profile" ]'
check "rc line removed"       '! grep -q "claude-profile\.sh" "$IH5/.zshrc"'
check "zshenv line removed"   '! grep -q "claude-profile/bin" "$IH5/.zshenv"'
check "store left alone"      '[ -d "$IH5/.claude-profiles/profiles/keepme" ]'
check "uninstall names the store" 'grep -qF "$IH5/.claude-profiles" "$TMP/uninstout"'

env $UENV sh "$HERE/install.sh" --uninstall >/dev/null 2>&1
eq "uninstall is idempotent" "$?" "0"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh 2>&1 | grep -i uninstall`
Expected: FAILs — `--uninstall` is not an option.

- [ ] **Step 3: Implement it**

Add `--uninstall) uninstall=1; shift ;;` to the argument loop, initialise `uninstall=""`, and add a line to `usage()`.

Add this helper next to the others:

```sh
# Drop our block and any line matching a pattern, leaving the rest of the file
# byte-for-byte. No sed -i: it is not POSIX.
drop_lines() {
    _f="$1"
    _pat="$2"
    [ -f "$_f" ] || return 0
    _t="$_f.cp-tmp.$$"
    grep -v "$_pat" "$_f" > "$_t" || : # grep exits 1 when nothing survives
    mv "$_t" "$_f" || { rm -f "$_t"; die "could not rewrite $_f"; }
}
```

Then, immediately after the argument loop and the `want_shell` / `rc` resolution (so `--rc` and `--shell` still apply) and before `copy_code`:

```sh
if [ -n "$uninstall" ]; then
    drop_lines "$rc" 'claude-profile\.sh'
    drop_lines "$rc" '# claude-profile'
    drop_lines "$ZSHENV" 'claude-profile'
    rm -f "$LINK_DIR/claude-profile"
    rm -rf "$INSTALL_DIR"
    say "removed $INSTALL_DIR, the PATH line, the rc line and the symlink"
    say ""
    say "Your profiles were not touched:"
    say ""
    say "    ${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}"
    exit 0
fi
```

`rm -rf "$INSTALL_DIR"` is the one destructive line in this repo. It is bounded to a path this script created, and `CLAUDE_PROFILE_INSTALL_DIR` is what the tests point elsewhere. Add a guard immediately above it so a mis-set env var cannot widen it:

```sh
    case "$INSTALL_DIR" in
        */.claude-profile|*/claude-profile) ;;
        *) die "refusing to remove $INSTALL_DIR: not a claude-profile install dir" ;;
    esac
```

- [ ] **Step 4: Run tests and shellcheck**

Run: `sh test.sh && shellcheck install.sh && dash -n install.sh`
Expected: `all passed`.

- [ ] **Step 5: Commit**

```bash
git add install.sh test.sh
git commit -m "feat: add install.sh --uninstall"
```

---

### Task 7: PowerShell — one store, agreed by both halves

**Files:**
- Modify: `claude-profile.psm1` (`Get-CpBaseDir` around line 52, `Get-CpStore` around line 42, `Start-CpClaude` around line 242)
- Test: `test.ps1`

**Interfaces:**
- Consumes: the store default from Task 1 and the skip rule from Task 2.
- Produces:
  - `Get-CpHome` — `$env:HOME` if set, else `$HOME`.
  - `Get-CpStore` — `$env:CLAUDE_PROFILES_DIR`, else `(Get-CpHome)\.claude-profiles`.
  - `Get-CpInstallDir` — `$env:CLAUDE_PROFILE_INSTALL_DIR`, else `(Get-CpHome)\.claude-profile`.
  - `Get-CpRealClaude` — the first `claude` Application on PATH that is not inside the install dir.

Why `Get-CpHome` must be extracted: `Get-CpBaseDir` already documents that Git Bash reads `HOME` from the environment while PowerShell's `$HOME` comes from `USERPROFILE`. Today a disagreement only moves `~/.claude`. Once the *store* is under the home directory, a disagreement means the two halves read different stores and list different profiles.

- [ ] **Step 1: Write the failing test**

Add to `test.ps1`, in the same style as the existing blocks (`Check -Name -Expected -Actual`, module internals reached with `& $mod { ... }`):

```powershell
Write-Host '--- store location ---'

$env:CLAUDE_PROFILES_DIR = $store
Check 'store: env wins' $store (& $mod { Get-CpStore })

$env:CLAUDE_PROFILES_DIR = $null
Check 'store: defaults under env HOME' (Join-Path $fakeHome '.claude-profiles') `
      (& $mod { Get-CpStore })
Check 'home: env HOME wins' $fakeHome (& $mod { Get-CpHome })

# PowerShell's $HOME is read-only, so the fallback branch is only reachable by
# clearing $env:HOME -- which is exactly what a plain PowerShell session has.
$env:HOME = $null
Check 'home: falls back to PowerShell $HOME' $HOME (& $mod { Get-CpHome })
Check 'store: defaults under PowerShell $HOME' (Join-Path $HOME '.claude-profiles') `
      (& $mod { Get-CpStore })
$env:HOME = $fakeHome
$env:CLAUDE_PROFILES_DIR = $store

Check 'install dir: defaults under home' (Join-Path $fakeHome '.claude-profile') `
      (& $mod { Get-CpInstallDir })
$env:CLAUDE_PROFILE_INSTALL_DIR = 'X:\somewhere'
Check 'install dir: env wins' 'X:\somewhere' (& $mod { Get-CpInstallDir })
$env:CLAUDE_PROFILE_INSTALL_DIR = $null
```

Then extend the existing drift-guard block (the one at line 135 that shells out to `Get-CpBash`) with a store comparison. Follow that block's existing shape — it sources `claude-profile.sh` under bash and compares against the sh implementation:

```powershell
        # Both halves derive the store from the home directory now, so drift
        # here means PowerShell and Git Bash would list different profiles.
        $probe = 'HOME=' + (& $mod { ConvertTo-CpPosixPath $fakeHome }) +
                 ' CLAUDE_PROFILES_DIR= ; . ./claude-profile.sh; _cp_store'
        $sh = (& $bash -c $probe) | Select-Object -Last 1
        $env:CLAUDE_PROFILES_DIR = $null
        $ps = & $mod { Get-CpStore }
        $env:CLAUDE_PROFILES_DIR = $store
        Check 'drift: both halves agree on the store' `
              (& $mod { ConvertTo-CpPosixPath $ps }) "$sh"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -ExecutionPolicy Bypass -File .\test.ps1`
Expected: FAIL on every `store:`, `home:` and `install dir:` line — those functions do not exist.

- [ ] **Step 3: Implement**

Replace `Get-CpStore` and the body of `Get-CpBaseDir` in `claude-profile.psm1`:

```powershell
# $env:HOME first, then PowerShell's $HOME. Git Bash takes HOME from the
# environment whenever it is set, and a good number of Windows setups do set it;
# PowerShell's $HOME comes from USERPROFILE and ignores it. Reading only $HOME
# here would leave the two halves of this tool disagreeing about where the store
# and the base ~/.claude are, on exactly the machines that had customised it.
function Get-CpHome {
    if ($env:HOME) { return $env:HOME }
    return $HOME
}

function Get-CpBaseDir {
    return (Join-Path (Get-CpHome) '.claude')
}

function Get-CpStore {
    if ($env:CLAUDE_PROFILES_DIR) { return $env:CLAUDE_PROFILES_DIR }
    return (Join-Path (Get-CpHome) '.claude-profiles')
}

function Get-CpInstallDir {
    if ($env:CLAUDE_PROFILE_INSTALL_DIR) { return $env:CLAUDE_PROFILE_INSTALL_DIR }
    return (Join-Path (Get-CpHome) '.claude-profile')
}
```

Keep the existing explanatory comment on `Get-CpBaseDir` — move it onto `Get-CpHome`, which is now where the rule lives.

- [ ] **Step 4: Make `Start-CpClaude` skip our own shim**

`-CommandType Application` already avoids the wrapper function, but a `claude.cmd` shim on PATH is an Application too. Replace the `$exe = Get-Command ...` lines with:

```powershell
    $exe = Get-CpRealClaude
    if (-not $exe) {
        Write-CpError 'claude-profile: cannot find claude on PATH.'
        $global:LASTEXITCODE = 127
        return
    }
```

and add:

```powershell
# -CommandType Application stops this resolving to the wrapper function, but the
# claude.cmd shim install.ps1 puts on PATH is an Application too -- resolving to
# that would recurse. Not pinned to .exe: the official install may be a .cmd.
function Get-CpRealClaude {
    $skip = [IO.Path]::GetFullPath((Get-CpInstallDir))
    foreach ($c in (Get-Command claude -CommandType Application -All -ErrorAction SilentlyContinue)) {
        $full = [IO.Path]::GetFullPath($c.Source)
        if (-not $full.StartsWith($skip, [StringComparison]::OrdinalIgnoreCase)) {
            return $full
        }
    }
    return $null
}
```

Then use `& $exe @ClaudeArgs` where the old code used `& $exe.Source @ClaudeArgs`.

- [ ] **Step 5: Add a resolver test**

```powershell
Write-Host '--- real claude resolution ---'

$shimDir = Join-Path $root '.claude-profile\bin'
$realDir = Join-Path $root 'realbin'
New-Item -ItemType Directory -Force -Path $shimDir, $realDir | Out-Null
Set-Content -Path (Join-Path $shimDir 'claude.cmd') -Value '@echo shim' -Encoding ASCII
Set-Content -Path (Join-Path $realDir 'claude.cmd') -Value '@echo real' -Encoding ASCII

$oldPath = $env:PATH
$env:CLAUDE_PROFILE_INSTALL_DIR = (Join-Path $root '.claude-profile')
$env:PATH = "$shimDir;$realDir"
Check 'resolver skips our own shim' (Join-Path $realDir 'claude.cmd') `
      (& $mod { Get-CpRealClaude })
$env:PATH = $shimDir
Check 'resolver returns nothing when only the shim is on PATH' '' `
      (& $mod { Get-CpRealClaude })
$env:PATH = $oldPath
$env:CLAUDE_PROFILE_INSTALL_DIR = $null
```

- [ ] **Step 6: Run the suites**

Run: `powershell -ExecutionPolicy Bypass -File .\test.ps1` and `sh test.sh`
Expected: both green. If Windows is not available, note in the commit body that `test.ps1` was not executed — do not claim it passed.

- [ ] **Step 7: Commit**

```bash
git add claude-profile.psm1 test.ps1
git commit -m "feat(windows): one store for both halves, and skip our own shim"
```

---

### Task 8: install.ps1 — stable dir, cmd shims, user PATH

**Files:**
- Modify: `install.ps1`
- Create: `bin/claude-profile.cmd`, `bin/claude.cmd`
- Test: `test.ps1`

**Interfaces:**
- Consumes: `Get-CpInstallDir` (Task 7), `--run-active` (Task 4).
- Produces: an installed tree at `%USERPROFILE%\.claude-profile`, two `.cmd` shims on the user PATH, and a `$PROFILE` import line pointing at the installed module. New switches: `-FromNpm`, `-NoShim`, `-Uninstall`.

Windows user PATH is persisted and inherited by every process, so both surfaces work everywhere here — including `cmd.exe` and Task Scheduler, which the POSIX side cannot reach.

- [ ] **Step 1: Create the two shims**

`bin/claude-profile.cmd`:

```bat
@echo off
rem Surface A on Windows. Management subcommands need Git Bash; the module
rem handles finding it and reports clearly when it is missing.
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "Import-Module '%~dp0..\claude-profile.psm1'; claude profile @args" %*
```

`bin/claude.cmd`:

```bat
@echo off
rem Surface B on Windows: cmd.exe and any non-interactive host never load
rem $PROFILE, so there is no claude function there. On PATH ahead of the real
rem binary, this reproduces what the function does.
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "Import-Module '%~dp0..\claude-profile.psm1'; claude @args" %*
```

Both must be ASCII with CRLF line endings. Add `*.cmd text eol=crlf` to `.gitattributes`.

- [ ] **Step 2: Write the failing test**

Add to `test.ps1`:

```powershell
Write-Host '--- install.ps1 ---'

$iHome    = Join-Path $root 'ihome'
$iProfile = Join-Path $iHome 'Profile.ps1'
New-Item -ItemType Directory -Force -Path $iHome | Out-Null
$env:HOME = $iHome
$env:CLAUDE_PROFILE_INSTALL_DIR = Join-Path $iHome '.claude-profile'

& (Join-Path $selfDir 'install.ps1') -ProfilePath $iProfile -FromNpm | Out-Null
Check 'install: exit code' 0 $LASTEXITCODE
Check 'install: module copied' $true `
      (Test-Path -LiteralPath (Join-Path $iHome '.claude-profile\claude-profile.psm1'))
Check 'install: lib copied' $true `
      (Test-Path -LiteralPath (Join-Path $iHome '.claude-profile\lib'))
Check 'install: surface A shim' $true `
      (Test-Path -LiteralPath (Join-Path $iHome '.claude-profile\bin\claude-profile.cmd'))
Check 'install: surface B shim' $true `
      (Test-Path -LiteralPath (Join-Path $iHome '.claude-profile\bin\claude.cmd'))
Check 'install: profile points at the install dir' $true `
      ([IO.File]::ReadAllText($iProfile).Contains((Join-Path $iHome '.claude-profile\claude-profile.psm1')))

# A clone-pointing import line is the state every existing user is in.
[IO.File]::WriteAllText($iProfile, "Import-Module '" + (Join-Path $selfDir 'claude-profile.psm1') + "'`r`n")
& (Join-Path $selfDir 'install.ps1') -ProfilePath $iProfile -FromNpm | Out-Null
Check 'install: rewrote a clone-pointing import' 0 $LASTEXITCODE
$lines = @([IO.File]::ReadAllText($iProfile) -split "`r?`n" |
           Where-Object { $_ -match 'claude-profile\.psm1' })
Check 'install: exactly one import line remains' 1 $lines.Count

& (Join-Path $selfDir 'install.ps1') -ProfilePath $iProfile -Uninstall | Out-Null
Check 'uninstall: exit code' 0 $LASTEXITCODE
Check 'uninstall: install dir gone' $false `
      (Test-Path -LiteralPath (Join-Path $iHome '.claude-profile'))
Check 'uninstall: import line gone' $false `
      ([IO.File]::ReadAllText($iProfile).Contains('claude-profile.psm1'))

$env:CLAUDE_PROFILE_INSTALL_DIR = $null
$env:HOME = $fakeHome
```

- [ ] **Step 3: Add the switches**

```powershell
param(
    [string] $ProfilePath,
    [switch] $NoShim,
    [switch] $FromNpm,
    [switch] $Uninstall,
    [switch] $Help
)
```

Extend the `-Help` text with one line per switch, matching the existing style.

- [ ] **Step 4: Install into the stable directory**

After `$selfDir` is computed, add:

```powershell
Import-Module (Join-Path $selfDir 'claude-profile.psm1') -Force
$installDir = & (Get-Module claude-profile) { Get-CpInstallDir }
$binDir     = Join-Path $installDir 'bin'
$module     = Join-Path $installDir 'claude-profile.psm1'
```

`$module` was previously `$selfDir\claude-profile.psm1`; every later use of it now points at the installed copy, which is the whole change in behaviour.

Add the copy step, called before the `$PROFILE` edit:

```powershell
function Copy-CpCode {
    if ($selfDir -eq $installDir) { return }
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    foreach ($item in @('claude-profile.psm1', 'claude-profile.sh', 'lib', 'bin')) {
        $src = Join-Path $selfDir $item
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $installDir $item
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    }
    if ($NoShim) {
        $s = Join-Path $binDir 'claude.cmd'
        if (Test-Path -LiteralPath $s) { Remove-Item -LiteralPath $s -Force }
    }
    Say "installed the code to $installDir"
}
```

- [ ] **Step 5: Prepend the bin dir to the user PATH, then verify it won**

```powershell
# System PATH is searched before user PATH, so prepending to user PATH is not a
# guarantee. Check rather than claim.
function Add-CpUserPath {
    if ($NoShim) { return }
    $user = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $user) { $user = '' }
    $parts = @($user -split ';' | Where-Object { $_ -ne '' })
    if ($parts -notcontains $binDir) {
        [Environment]::SetEnvironmentVariable('PATH', (@($binDir) + $parts) -join ';', 'User')
        Say "prepended $binDir to your user PATH"
    } else {
        Say "$binDir already on your user PATH"
    }
    $env:PATH = "$binDir;$env:PATH"

    $winner = (Get-Command claude -CommandType Application -All -ErrorAction SilentlyContinue |
               Select-Object -First 1)
    if ($winner -and -not $winner.Source.StartsWith($installDir, [StringComparison]::OrdinalIgnoreCase)) {
        Warn ""
        Warn "install: the claude that wins on PATH is still"
        Warn "    $($winner.Source)"
        Warn "System PATH is searched before user PATH, so `claude profile` will not be"
        Warn "intercepted outside PowerShell. `claude-profile` still works everywhere."
        Warn ""
    }
}
```

- [ ] **Step 6: Rewrite a clone-pointing import line instead of refusing**

In the `if ($existingText -match 'claude-profile\.psm1')` branch, replace the `Die` path with a rewrite that keeps the first match and drops the rest:

```powershell
    if ($hasExact) {
        Say "already installed in $target"
    } else {
        $out  = New-Object System.Collections.Generic.List[string]
        $done = $false
        foreach ($l in ($existingText -split "`r?`n")) {
            if ($l -match 'claude-profile\.psm1') {
                if (-not $done) { $out.Add($line); $done = $true }
                continue
            }
            $out.Add($l)
        }
        [IO.File]::WriteAllText($target, ($out -join "`r`n"),
                                (New-Object System.Text.UTF8Encoding($true)))
        Say "pointed the import line in $target at $module"
    }
```

- [ ] **Step 7: Add `-Uninstall` and honour `-FromNpm`**

`-Uninstall`, placed right after `$binDir` is known and before `Copy-CpCode`:

```powershell
if ($Uninstall) {
    if ($installDir -notmatch '[\\/]\.?claude-profile$') {
        Die "refusing to remove $installDir : not a claude-profile install dir"
    }
    $user  = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $parts = @($user -split ';' | Where-Object { $_ -ne '' -and $_ -ne $binDir })
    [Environment]::SetEnvironmentVariable('PATH', ($parts -join ';'), 'User')
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $kept = @([IO.File]::ReadAllText($target) -split "`r?`n" |
                  Where-Object { $_ -notmatch 'claude-profile' })
        [IO.File]::WriteAllText($target, ($kept -join "`r`n"),
                                (New-Object System.Text.UTF8Encoding($true)))
    }
    if (Test-Path -LiteralPath $installDir) {
        Remove-Item -LiteralPath $installDir -Recurse -Force
    }
    Say "removed $installDir, the PATH entry and the import line"
    Say ""
    Say "Your profiles were not touched:"
    Say ""
    Say "    $(& (Get-Module claude-profile) { Get-CpStore })"
    exit 0
}
```

For `-FromNpm`: skip the fresh-session verification block (it spawns a host and needs a console), and print the `--migrate-store` hint in the closing summary.

- [ ] **Step 8: Run the suites**

Run: `powershell -ExecutionPolicy Bypass -File .\test.ps1`
Expected: green. Also re-run `sh test.sh` — nothing here should affect it. If no Windows machine is available, say so in the commit body rather than claiming a pass.

- [ ] **Step 9: Commit**

```bash
git add install.ps1 bin/claude-profile.cmd bin/claude.cmd .gitattributes test.ps1
git commit -m "feat(windows): install to a stable dir with cmd shims on user PATH"
```

---

### Task 9: npm package with a dispatching postinstall

**Files:**
- Create: `package.json`
- Create: `scripts/postinstall.mjs`
- Create: `bin/claude-profile-install.mjs`
- Test: `test.sh` (new section)

**Interfaces:**
- Consumes: `install.sh --from-npm` (Task 5), `install.ps1 -FromNpm` (Task 8).
- Produces: `npm i -g claude-profiles` delivers the code and runs the right installer. The npm-generated bin is bootstrap-only; the working `claude-profile` on PATH is the symlink from Task 5.

Why the dispatcher holds no logic: the npm global prefix is node-version-scoped (`~/.nvm/versions/node/vX/`), so anything that depends on it disappears on `nvm install`. Only the installers may write to PATH or rc, and they already do.

- [ ] **Step 1: Write the failing test**

Append to `test.sh`:

```sh
echo "== Task 20: npm packaging =="

check_with "package.json is valid JSON" node \
   'node -e "JSON.parse(require(\"fs\").readFileSync(\"$HERE/package.json\",\"utf8\"))"'
check_with "package ships the code, not the store" node \
   'node -e "
      const f = JSON.parse(require(\"fs\").readFileSync(\"$HERE/package.json\",\"utf8\")).files;
      const need = [\"claude-profile.sh\",\"lib\",\"bin\",\"claude-profile.psm1\",\"install.sh\",\"install.ps1\"];
      for (const n of need) if (!f.includes(n)) { console.error(\"missing \"+n); process.exit(1); }
      for (const n of [\"profiles\",\"exports\",\".backups\"]) if (f.includes(n)) { console.error(\"ships \"+n); process.exit(1); }
   "'
check_with "postinstall is wired to the dispatcher" node \
   'node -e "
      const p = JSON.parse(require(\"fs\").readFileSync(\"$HERE/package.json\",\"utf8\"));
      if (!/postinstall\.mjs/.test(p.scripts.postinstall)) process.exit(1);
   "'
check_with "dispatcher runs the POSIX installer" node \
   'env HOME="$TMP/npmhome" CP_RC="$TMP/npmhome/.zshrc" CP_ZSHENV="$TMP/npmhome/.zshenv" \
        CP_LINK_DIR="$TMP/npmhome/.local/bin" \
        CLAUDE_PROFILE_INSTALL_DIR="$TMP/npmhome/.claude-profile" SHELL=/bin/zsh \
        node "$HERE/scripts/postinstall.mjs" >/dev/null 2>&1 &&
    [ -f "$TMP/npmhome/.claude-profile/claude-profile.sh" ]'
```

Create `$TMP/npmhome` with `mkdir -p` on the line before.

- [ ] **Step 2: Run test to verify it fails**

Run: `sh test.sh 2>&1 | grep -E "package|postinstall|dispatcher"`
Expected: FAILs — none of those files exist.

- [ ] **Step 3: Write `package.json`**

```json
{
  "name": "claude-profiles",
  "version": "0.1.0",
  "description": "Switch Claude Code between isolated config profiles from any shell",
  "license": "MIT",
  "bin": {
    "claude-profile-install": "bin/claude-profile-install.mjs"
  },
  "files": [
    "claude-profile.sh",
    "claude-profile.psm1",
    "lib",
    "bin",
    "install.sh",
    "install.ps1",
    "README.md",
    "LICENSE"
  ],
  "scripts": {
    "postinstall": "node scripts/postinstall.mjs",
    "test": "sh test.sh"
  },
  "engines": { "node": ">=18" }
}
```

The npm bin is deliberately named `claude-profile-install`, not `claude-profile`: the real `claude-profile` on PATH is the symlink from Task 5, which survives node version changes. An npm bin of the same name would shadow it from a directory that disappears on `nvm install`.

- [ ] **Step 4: Write `scripts/postinstall.mjs`**

```javascript
// npm delivers the code; the installers own PATH and rc. Keeping the logic there
// means one implementation per platform, not three.
//
// A failed postinstall must not fail the install: a user who installs on a
// locked-down machine should still get a package they can install by hand.
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));

const [cmd, args] = process.platform === 'win32'
  ? ['powershell', ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', join(root, 'install.ps1'), '-FromNpm']]
  : ['sh', [join(root, 'install.sh'), '--from-npm']];

const run = spawnSync(cmd, args, { stdio: 'inherit', cwd: root });

if (run.status !== 0) {
  console.error('\nclaude-profiles: the installer did not finish. Run it by hand:');
  console.error(process.platform === 'win32'
    ? `    powershell -ExecutionPolicy Bypass -File "${join(root, 'install.ps1')}"`
    : `    sh "${join(root, 'install.sh')}"`);
}
```

- [ ] **Step 5: Write `bin/claude-profile-install.mjs`**

```javascript
#!/usr/bin/env node
// Re-runs the installer, for when a shell rc was reset or the install dir was
// removed. The same dispatcher npm's postinstall uses.
import('../scripts/postinstall.mjs');
```

`chmod +x bin/claude-profile-install.mjs`.

- [ ] **Step 6: Verify the packed contents**

Run: `npm pack --dry-run`
Expected: the listing contains `claude-profile.sh`, `lib/`, `bin/`, `install.sh`, `install.ps1`; it contains no `profiles/`, `exports/`, `.backups/`, `test.sh` or `docs/`.

- [ ] **Step 7: Run the suite**

Run: `sh test.sh`
Expected: `all passed`.

- [ ] **Step 8: Commit**

```bash
git add package.json scripts/postinstall.mjs bin/claude-profile-install.mjs test.sh
git commit -m "feat: ship as an npm package with a dispatching postinstall"
```

---

### Task 10: README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above. No code.

- [ ] **Step 1: Read the README and find the install section**

Run: `grep -n '^#' README.md`

- [ ] **Step 2: Rewrite install and add the coverage table**

Cover, in the README's existing voice:

- `npm i -g claude-profiles` as the first-listed install; `git clone && ./install.sh` kept as the second.
- The store lives at `~/.claude-profiles`, outside the code, and `CLAUDE_PROFILES_DIR` overrides it.
- Upgrading from a clone: `claude-profile --migrate-store ~/claude-profiles`, and that `install.sh` does it automatically when run from a clone that has a store.
- The two surfaces, with the coverage table copied from the spec's §5. Be explicit that `claude profile` is not intercepted under `sh -c` or cron on macOS/Linux and that `claude-profile` is the answer there.
- `--no-shim`, and `install.sh --uninstall` / `install.ps1 -Uninstall`.
- That npm is delivery only: nothing on PATH or in an rc file points into the node prefix, so changing node version does not break an install.

- [ ] **Step 3: Check the examples are real**

Run every command block you wrote against a scratch `HOME`, the way the Task 5 tests do. Fix the docs, not the test.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: install, store location and shell coverage"
```

---

## Self-Review

**Spec coverage:** §1 → Task 1. §2 → Task 3 (installer hook in Task 5). §3 → Tasks 4, 5. §4 → Task 2. §5 → Task 5. §6 → Task 6. §7 → Task 7. §8 → Task 8. §9 → Task 9. Spec test lists → the test steps of Tasks 1-9. README → Task 10.

**Type/name consistency:** `_cp_store`, `_cp_install_dir`, `_cp_deref`, `_cp_real_claude`, `_cp_migrate_store`, `_cp_migrate_rewrite`, `--run-active`, `--migrate-store`, `--no-shim`, `--from-npm`, `--uninstall` are spelled identically everywhere they appear. PowerShell: `Get-CpHome`, `Get-CpStore`, `Get-CpInstallDir`, `Get-CpRealClaude`, `-NoShim`, `-FromNpm`, `-Uninstall`. Env seams: `CLAUDE_PROFILES_DIR`, `CLAUDE_PROFILE_INSTALL_DIR`, `CP_RC`, `CP_LINK_DIR`, `CP_ZSHENV`.

**Known deviations from the spec, deliberate:**
- The spec mentions `claude-profile --install`. It is not implemented: `install.sh` is the installer and the npm bin `claude-profile-install` re-runs it, so a third spelling would be a third code path with nothing new behind it.
- Task 6 and Task 8 add a guard on the install-dir name before any recursive delete. The spec did not ask for it; a recursive delete driven by an env var needs it.
