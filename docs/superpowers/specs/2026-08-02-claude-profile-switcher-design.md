# claude-profile — design

**Date:** 2026-08-02
**Status:** approved, ready for implementation plan

## Problem

Claude Code keeps all configuration in one directory (`~/.claude`): enabled plugins, personal
skills, commands, hooks, MCP servers, model choice, permissions, statusline. Testing a different
setup means editing that directory in place and remembering how to undo it. There is no way to
keep a "development" setup and a "finance" setup side by side, and no way to hand a colleague a
setup you have tuned.

## Goal

A shell wrapper that swaps the whole Claude Code configuration directory per profile, plus
commands to snapshot the current setup into a profile and manage those profiles. Distributed as
a git repository so colleagues can clone and use it.

Non-goal: a general dotfile manager. This tool knows about Claude Code's directory layout and
nothing else.

## Key insight

Claude Code natively honours the `CLAUDE_CONFIG_DIR` environment variable (verified: 28 references
in the 2.1.220 binary). A profile is therefore just a directory, and switching is setting one
variable. No plugin loader, no config merging, no patching of Claude Code itself.

## Architecture

### Store layout

Default store is the repository clone itself. Override with `$CLAUDE_PROFILES_DIR`.

```
claude-profiles/                 the clone
  claude-profile.sh              tracked — the wrapper
  test.sh                        tracked — self-check
  README.md                      tracked
  .gitignore                     tracked
  docs/                          tracked
  profiles/<name>/               IGNORED — a complete CLAUDE_CONFIG_DIR
  active                         IGNORED — one line, the active profile name
  .backups/<name>-<ts>/          IGNORED — pre-update snapshots
```

`profiles/`, `active` and `.backups/` are gitignored without exception. A profile's `settings.json`
can contain environment variables and API keys; committing profiles would leak them. The repository
ships the tool, never the data.

### Profile contents

A profile is a full `CLAUDE_CONFIG_DIR`. It is built by copying everything from the source config
directory **except** a fixed shared list, whose members are symlinked back to `~/.claude` instead.

**Symlinked (shared across all profiles):**

| Path | Reason |
|---|---|
| `plugins/` | 371 MB download cache. Install once, enable per profile via `settings.json`. |
| `projects/` | 327 MB of per-project session history. Not part of a "setup". |
| `history.jsonl` | Prompt history. Shared is the useful behaviour. |
| `.credentials.json` | Avoids re-authenticating per profile. |
| `context-mode/` | Plugin knowledge base, 6.6 MB, not setup. |
| `file-history/` `cache/` `sessions/` `shell-snapshots/` `backups/` `telemetry/` `tasks/` `paste-cache/` `debug/` `downloads/` `ide/` `chrome/` `session-env/` | Runtime state. |
| `.session-stats.json` `stats-cache.json` `claude-devtools-notifications.json` | Runtime state. |

**Copied (everything else, per profile):** `settings.json`, `CLAUDE.md` and any other root `*.md`,
`skills/`, `commands/`, `hooks/`, `agents/`, `scripts/`, `statusline.sh`, `.claude.json` (MCP
servers), `.caveman-active`, `.ponytail-active`, `teams/`, `agentic-os/`.

Copy-the-rest rather than an allowlist: a future Claude Code version that adds a config file gets
carried into profiles automatically, with no edit to this tool. The two large directories are on
the shared list, so copying the remainder costs under 10 MB.

`.DS_Store` is skipped.

### settings.json path rewriting

`settings.json` contains absolute paths into the config directory — in the observed case
`hooks/rtk-rewrite.sh`, `hooks/context-mode-cache-heal.mjs`, and `statusline.sh`. Copied verbatim,
a profile's own `hooks/` and `statusline.sh` would be dead weight while base's copies keep running.

On create and update, the literal prefix `$HOME/.claude/` is rewritten to the profile directory
throughout `settings.json`. Both the expanded form (`/Users/<user>/.claude/`) and the literal
`~/.claude/` and `$HOME/.claude/` forms are handled. Paths outside the config directory
(`~/.local/bin/headroom`, `~/agentic-os-myparcel/scripts/...`) are left untouched.

The prefix is derived from `$HOME` at runtime. No username is hardcoded anywhere in the tool.

### Resolution order

Every `claude` invocation resolves a config directory, most specific first:

1. `$CLAUDE_PROFILE` — one invocation
2. `.claude-profile` — first one found walking up from `$PWD` to `/`; contains a profile name
3. `active` — the global default in the store
4. base `~/.claude` — no profile

A named profile that does not exist is a warning and a fall back to base, never a hard failure —
a stale `.claude-profile` in a repo must not make `claude` unusable.

`claude profile` with no arguments prints the resolved profile *and which rule produced it*.

### Wiring

A POSIX-sh function sourced from `~/.zshrc` or `~/.bashrc`:

```sh
claude() {
  if [ "$1" = profile ]; then shift; _cp_main "$@"; return $?; fi
  CLAUDE_CONFIG_DIR="$(_cp_resolve)" command claude "$@"
}
```

No zsh-only syntax: no arrays, no `${(f)}`, no `[[ =~ ]]`. Tested under both shells.

Reversible by deleting the `source` line. Scripts that invoke `claude` directly bypass the function
and get base `~/.claude`, which is the safe default.

## Commands

| Command | Behaviour |
|---|---|
| `claude profile` | Active profile, which rule selected it, and the list of profiles |
| `claude profile <name>` | Set the global active profile |
| `claude profile default` | Clear the active profile. Alias: `--reset` |
| `claude profile <name> -- <args>` | Run one session in that profile; active unchanged |
| `claude profile --create <name>` | Snapshot the currently resolved setup into a new profile |
| `claude profile --update <name>` | Mirror the currently resolved setup into an existing profile |
| `claude profile --delete <name>` | Delete a profile |
| `claude profile --rename <a> <b>` | Rename |
| `claude profile --copy <a> <b>` | Duplicate |
| `claude profile --show <name>` | Model, enabled plugins, personal skills, hook count, MCP servers |
| `claude profile --diff <a> <b>` | The same fields, compared |
| `claude profile --export <name> [path]` | Write a portable tarball; defaults to `./<name>.tar.gz` |
| `claude profile --import <file> [name]` | Create a profile from a tarball; name defaults to the one in the archive |
| `claude profile --install-statusline` | Opt-in statusline integration |
| `claude profile --uninstall-statusline` | Remove it |

### create

Source is the currently resolved config directory — the active profile if one is active, otherwise
base `~/.claude`. This makes forking a tuned profile the default behaviour, which is the point of
the tool. Fails if the target name already exists.

### update

Mirror semantics: after `--update`, the profile equals the source. A skill deleted in the source is
deleted in the profile. Before writing, the profile's current contents are moved to
`.backups/<name>-<YYYYmmdd-HHMMSS>/`.

The backup is not optional. Git versioning of the store was considered and rejected, so this is the
only rollback path, and a mistyped profile name on a tuned setup is otherwise unrecoverable.

Refuses when the source and target are the same profile — it would be a no-op that destroys the
backup slot.

Prints a summary of what changed per top-level entry.

### delete

Refuses to delete the active profile. Requires typing the profile name to confirm. Moves to
`.backups/` rather than unlinking, same as update.

### export / import

Export contains only the copied, profile-scoped files — never the shared symlink targets, and
`.credentials.json` is excluded explicitly rather than relying on it being a symlink. Import
recreates the shared symlinks against the importing machine's `~/.claude`, and re-runs the
`settings.json` path rewrite for the new location and user.

Export refuses if `.credentials.json` is a regular file rather than a symlink, since that means the
profile was built by something other than this tool and could carry a real token.

### statusline

Opt-in. `--install-statusline` backs up `~/.claude/statusline.sh`, creates it if absent, and appends
a guarded, idempotent block:

```sh
# CLAUDE_PROFILE_BLOCK start
[ -n "$CLAUDE_CONFIG_DIR" ] && printf ' · [%s]' "${CLAUDE_CONFIG_DIR##*/}"
# CLAUDE_PROFILE_BLOCK end
```

Because the block lives in base `~/.claude/statusline.sh`, every profile created afterwards inherits
it through the normal copy. It prints nothing when no profile is active, so base behaviour is
unchanged. `--uninstall-statusline` removes the guarded block.

## Safety rules

These are not configurable.

1. Nothing writes to `~/.claude` except `--install-statusline` / `--uninstall-statusline`.
2. `--export` never includes credentials.
3. `--delete` refuses the active profile and requires confirmation.
4. `--update` and `--delete` back up before destroying.
5. `profiles/`, `active`, `.backups/` are gitignored.
6. A missing or broken profile degrades to base with a warning, never a hard failure.
7. No username, home directory, or machine-specific path is hardcoded.

## Testing

`test.sh` runs against a temporary store and a temporary fake `~/.claude`, so it never touches real
configuration. It asserts:

- create produces the shared symlinks and real copies in the right places
- `settings.json` paths are rewritten to the profile, and non-config absolute paths are not
- resolution order: env var beats pin beats active beats base
- a stale `.claude-profile` degrades to base rather than failing
- update mirrors, and the previous contents land in `.backups/`
- update refuses when source equals target
- delete refuses the active profile
- export excludes `.credentials.json`
- the statusline block is idempotent — installing twice yields one block
- the script is POSIX-clean under both `sh` and `bash`

## Deliverables

| File | Purpose |
|---|---|
| `claude-profile.sh` | The wrapper and all subcommands |
| `test.sh` | Self-check described above |
| `README.md` | Install, commands, what is and is not shared, uninstall |
| `.gitignore` | `profiles/`, `active`, `.backups/` |

## Rejected

- **Selective file swapping inside `~/.claude`** — mutates live config on every switch; a crash
  mid-switch leaves it half-swapped.
- **Fully standalone profiles with no sharing** — forces re-authentication per profile and
  duplicates a 371 MB plugin cache.
- **Git-versioned store with auto-commit** — rejected in favour of `.backups/`. Revisit if backups
  prove insufficient.
- **Executable shim earlier in `PATH`** — intercepts every caller including scripts, cron and IDEs;
  a `PATH` mistake makes `claude` unreachable.
- **Committing profiles to the repo** — leaks secrets from `settings.json`.
