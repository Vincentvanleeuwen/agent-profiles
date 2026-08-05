# Making claude-profile work outside its own clone

Date: 2026-08-04
Status: approved design, ready for implementation planning

## Problem

`claude profile <name>` only works in interactive shells. `.zshrc` — where the
installer puts the source line — is read by interactive shells only. In every
other context (`zsh -c`, `sh -c`, scripts, cron, the Claude Code Bash tool,
other agents) the `claude` shell function does not exist, so `claude profile
trader` is handed to the real `claude` binary as two arguments. The session
then silently runs on `~/.claude` instead of the selected profile.

This was misread as a per-directory problem. It is not. Verified:

```
interactive zsh, any directory   claude is a shell function     OK
zsh -c / sh -c / scripts         claude is ~/.local/bin/claude  broken
```

Nothing in the tool is cwd-dependent except the optional `.claude-profile`
pin lookup. All store paths are absolute, derived from `_CP_HOME`.

Second gap: there is no `claude-profile` executable on PATH at all, even
though `claude-profile.sh` already resolves its own `lib/` through `readlink`
(`_cp_libdir`) specifically so it can be symlinked into a `bin` directory.
The installer never does it.

## Goals

- `claude-profile <name>` works in every context, including `sh -c` and cron.
- `claude profile <name>` works in non-interactive zsh and on Windows.
- Installable on a new machine with `npm i -g claude-profiles`.
- A node version change must never break an existing install.
- The bash half and the PowerShell half must always agree on one store.

## Non-goals

- `claude profile <name>` under `sh -c`, cron, or GUI-launched processes on
  macOS/Linux. Not achievable without owning a PATH directory that is already
  inherited ahead of `~/.local/bin`. Surface A covers those cases instead.
- `BASH_ENV` wiring for non-interactive bash. Fragile, low value.
- Any change to how profiles themselves are built or synced.

## Constraint discovered: npm prefix is node-version-scoped

```
npm config get prefix -> /Users/…/.nvm/versions/node/v24.18.0
```

Two consequences that shape the whole design:

1. npm's global bin dir sits *after* `~/.local/bin` in PATH, and
   `~/.local/bin/claude` is the official binary. An npm-installed `claude`
   shim could never win.
2. `nvm install 25` removes the package. A rc line pointing into the nvm
   prefix would then error in every new shell and `claude` would silently
   revert to the raw binary — the original bug, reintroduced by its own fix.

Therefore **npm is a delivery mechanism only.** It must not own PATH or rc.

## Design

### §1 Store relocation

`_cp_store()` (`lib/resolve.sh:11`, the single place the default lives)
becomes `${CLAUDE_PROFILES_DIR:-$HOME/.claude-profiles}`. The store never
lives inside installed code, so npm upgrades cannot touch profile data.

All store contents are already gitignored (`profiles/`, `active`, `exports/`,
`.backups/`, `prompt-state.json`), so nothing leaves version control by
moving them.

### §2 Migration, with a scoped rewrite

Each profile's `settings.json` hardcodes absolute paths into the store:

```
profiles/development/settings.json:31  ".../claude-profiles/profiles/development/hooks/rtk-rewrite.sh"
profiles/development/settings.json:69  ".../claude-profiles/profiles/development/statusline.sh"
```

Moving the store without rewriting these breaks every hook and the
statusline, silently. A blanket rewrite is also wrong: `.claude.json` and
`teams/*/config.json` contain project-history `cwd` keys pointing at the repo
directory, which still exists and must keep pointing there.

New `_cp_migrate_store <legacy-dir>`:

- moves `profiles/ active exports/ .backups/ prompt-state.json` into the new store
- refuses if the target is already non-empty; idempotent on re-run
- copies every file it is about to rewrite into
  `<new>/.backups/migrate-<timestamp>/`, then replaces the literal
  `<legacy>/profiles/` with `<new>/profiles/` **only** in
  `profiles/*/settings.json`, `profiles/*/settings.local.json`,
  `profiles/*/statusline.sh`, `profiles/*/hooks/*`
- leaves `.claude.json` and `teams/*/config.json` untouched
- prints what it moved and every file it rewrote

`install.sh` run from a clone calls it automatically with its own directory.
The npm postinstall cannot detect a legacy clone, so it prints one line:
`claude-profile --migrate-store ~/claude-profiles`.

### §3 Stable install directory

`postinstall`, and the idempotent `claude-profile --install`, write:

```
~/.claude-profile/                    code copy: claude-profile.sh, lib/, claude-profile.psm1
~/.claude-profile/bin/claude-profile  entry point
~/.claude-profile/bin/claude          shim, opt out with --no-shim
```

Nothing on PATH or in any rc file references the nvm prefix, so a node
version change cannot break an install. npm's own `bin` entry is
bootstrap-only: it runs the installer and nothing else.

### §4 Real-binary discovery

`_cp_run_claude` currently calls `command claude` (`lib/commands.sh:67`).
With a shim named `claude` on PATH that recurses forever.

New `_cp_real_claude`: walk `$PATH`, resolve each `claude` candidate through
`readlink`, skip any whose resolved path is under `~/.claude-profile`, return
the first survivor. `_CP_RUNNER` stays the override hook used by tests.

### §5 PATH and rc wiring (POSIX)

Two deliberately separate surfaces:

- `~/.local/bin/claude-profile` — a symlink. That directory is inherited on
  PATH in every context, so surface A works in `sh -c`, cron, GUI-launched
  tools and other agents. This is the reliable surface.
- `~/.claude-profile/bin` prepended in **`.zshenv`**, which every zsh reads
  (unlike `.zshrc`). Gives surface B in non-interactive zsh. Best-effort.

| context | `claude-profile x` | `claude profile x` |
|---|---|---|
| interactive zsh | yes, symlink | yes, shell function |
| `zsh -c`, zsh scripts, Claude Code Bash tool | yes | yes, `.zshenv` |
| `bash -c` | yes | no — would need `BASH_ENV`, out of scope |
| `sh -c`, cron, GUI apps | yes | no — see non-goals |

In interactive shells the shell function wins over PATH regardless of
ordering, so a later `~/.local/bin` prepend in `.zshrc` cannot shadow the
shim where it matters.

The installer must **rewrite** an existing source line that points at a clone
(currently `.zshrc:125`, `source ~/claude-profiles/claude-profile.sh`) to the
stable path. Today `install.sh` hard-errors when it finds a line that differs
from what it would write; that path must migrate instead of refuse.

### §6 Uninstall

`claude-profile --uninstall` removes `~/.claude-profile`, the `.zshenv` PATH
line, the rc source line, and the `~/.local/bin/claude-profile` symlink. It
never touches the store, and prints the store path so the user knows where
their data still is.

### §7 Windows: both halves must agree on the store

`Get-CpStore` defaults to `$script:CpRoot` (`$PSScriptRoot`) — the same
single-point default as bash.

`Get-CpBaseDir` already documents the hazard: Git Bash takes `HOME` from the
environment, PowerShell's `$HOME` comes from `USERPROFILE`, and they disagree
on machines that set `HOME`. Today that only affects where `~/.claude` is.
Once the *store* is `~/.claude-profiles`, a disagreement means the PowerShell
half and the Git Bash half read different stores, and `claude profile` lists
different profiles depending on which half you are in.

Extract that `$env:HOME`-then-`$HOME` rule out of `Get-CpBaseDir` into
`Get-CpHome`, and use it for both `~/.claude` and the store default.
`Get-CpStore` becomes `$env:CLAUDE_PROFILES_DIR`, else
`Join-Path (Get-CpHome) '.claude-profiles'`.

### §8 Windows PATH

Windows user PATH is persisted and inherited by every process, so both
surfaces work everywhere there — including `cmd.exe` and Task Scheduler,
which macOS cannot match.

```
%USERPROFILE%\.claude-profile\bin\claude-profile.cmd   surface A
%USERPROFILE%\.claude-profile\bin\claude.cmd           surface B, shim
```

`install.ps1` prepends that directory to the user PATH and then **verifies**
by resolving `claude`, warning if the official binary still wins — system
PATH outranks user PATH, so this is possible. The shim obeys the same
recursion rule as §4.

`$PROFILE` handling mirrors §5: rewrite an existing `Import-Module` line to
the stable path rather than refusing.

### §9 npm postinstall, cross-platform

`postinstall` is a small node script that only dispatches:
`sh install.sh --from-npm` on POSIX, `powershell -File install.ps1 -FromNpm`
on Windows. No install logic is duplicated in node — the two existing
installers remain the single source of truth.

`files` in `package.json` ships `claude-profile.sh`, `lib/`,
`claude-profile.psm1`, `install.sh`, `install.ps1`. It never ships
`profiles/`, `exports/` or `.backups/`.

`--from-npm` / `-FromNpm` means: non-interactive, no prompts, skip the
fresh-shell verification that needs a tty, and print the
`--migrate-store` hint.

## Tests

`test.sh`:

- store default resolves to `$HOME/.claude-profiles`; `CLAUDE_PROFILES_DIR` still overrides
- migration moves the expected entries and is idempotent
- migration rewrites `settings.json` **and** leaves `.claude.json` untouched
- `_cp_real_claude` skips a fake shim placed ahead of a fake binary on PATH
- `--install` twice is a no-op the second time; `--uninstall` reverses it
- installer rewrites a clone-pointing rc line instead of erroring

`test.ps1`:

- store default with `HOME` set and unset
- bash half and PowerShell half resolve the same store path
- shim resolver skips a fake shim
- `--install` / `--uninstall` idempotency
- `$PROFILE` `Import-Module` line rewrite

## Risks

- **Shim shadows a vendor binary.** Mitigated by dynamic resolution (survives
  claude self-update) and `--no-shim`. Failure mode is fail-safe: if the shim
  disappears, `claude` reverts to today's behaviour.
- **Migration rewrite.** Scoped to four file patterns, backed up first, with a
  test asserting `.claude.json` is not touched.
- **Windows user PATH may lose to system PATH.** Installer detects and warns
  rather than claiming success.

## Order of work

1. Store default + migration + tests (independent, unblocks everything).
2. `_cp_real_claude` + tests.
3. `--install` / `--uninstall` / `--no-shim`, rc and `.zshenv` wiring, POSIX.
4. Windows: `Get-CpHome`, store default, bin shims, user PATH, `$PROFILE`.
5. `package.json` + postinstall dispatcher.
6. README: the coverage matrix, the store location change, the migration command.
