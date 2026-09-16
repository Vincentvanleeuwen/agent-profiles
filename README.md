# Agent Profiles

Switch Claude Code and Codex between named configuration profiles without
editing `~/.claude` or `~/.codex` by hand.

A profile is a complete `CLAUDE_CONFIG_DIR`. Claude Code honours that variable
natively, so switching is just pointing it somewhere else. Each profile also
owns a `codex.config.toml`. The switcher links `~/.codex/config.toml` to that
file, which covers both the Codex CLI and desktop app. Claude settings are not
translated; each tool keeps its native configuration.

## Install

```sh
npm i -g agent-profiles
```

or, from a clone:

```sh
git clone <this repo> ~/agent-profiles
~/agent-profiles/install.sh
```

Either way you end up with two things on PATH: `agent-profile`, a new command
for managing profiles, and a `claude` wrapper that points the real binary at
whichever profile is active. Both are copied into a stable `~/.agent-profile`
(singular — a different directory from where your profiles themselves live,
see [Where the data lives](#where-the-data-lives)), so nothing on PATH or in
any rc file points into an npm/nvm prefix: changing your node version cannot
break an existing install. npm is delivery only — its postinstall just runs
the same `install.sh` under the hood. Set `CLAUDE_PROFILE_INSTALL_DIR` to put
the code somewhere else; `install.sh` refuses to run, before touching
anything, if that resolves to `/`, to `$HOME` itself, or to an ancestor of
`$HOME` — it gets `rm -rf`'d on `--uninstall`, and any of those would make
that catastrophic. It also refuses early, before anything is touched, if
`$HOME` itself does not resolve to a real directory.

`claude-profile` remains an alias for existing scripts. On upgrade, the POSIX
installer moves the old default directories from `~/.claude-profile` and
`~/.claude-profiles` to `~/.agent-profile` and `~/.agent-profiles`. The legacy
`.claude-profile` project pin and `CLAUDE_PROFILE*` environment variables stay
compatible.

On Windows, npm's postinstall cannot yet run the unmigrated `install.ps1` and
prints a message telling you to clone the repo and run it yourself instead.
See [Windows](#windows). Codex switching is currently available through the
POSIX installer only; PowerShell still switches Claude alone.

`install.sh` adds the `source` line to your `~/.zshrc`, `~/.bashrc` or
`~/.bash_profile` — whichever your shell actually reads, which differs between
macOS, Linux and Git Bash — then starts real shells, login and non-login, and
looks at what `claude` resolves to in each, because a line in a file is not an
install. Re-running it is a no-op.

Bash is the awkward one. It reads `~/.bashrc` for interactive non-login shells
and the first of `~/.bash_profile`, `~/.bash_login` or `~/.profile` for login
shells, with no fallback between the two — so a source line in `.bashrc` is
invisible to `bash -l`, `su -` and most container entrypoints. Where none of the
login files exist, as on a bare account or container image, it writes a
`~/.bash_profile` that sources `~/.bashrc`. Where one exists and does not source
it, it prints the line to add, leaves the file alone, and exits non-zero: the
wrapper works in some of your shells but not all of them. zsh needs none of
this, which is why this never came up on macOS.

It works out the shell from `$SHELL`, then from the process that invoked it,
then from which rc files exist. When that genuinely cannot be settled — both a
zsh and a bash rc present, and `$SHELL` pointing at neither — it stops and asks
rather than guessing:

```sh
./install.sh --shell bash      # or zsh
./install.sh --rc ~/.profile   # or name the file outright
```

An existing line pointing at a different clone gets rewritten to point at the
stable install instead — see [Moving off an old
clone](#moving-off-an-old-clone) below for what else that involves.

Start a new shell, then snapshot your current setup:

```sh
agent-profile --create development
agent-profile development
```

`claude` and Codex now use that profile. `agent-profile default` goes back to
plain `~/.claude` and the original Codex config.

The first switch preserves the existing `~/.codex/config.toml` as
`~/.agent-profiles/codex-default.config.toml`. Existing profiles get a copy of
that default the first time they are selected. Restart an open Codex session
after switching; running sessions keep the settings they started with.

### The two commands

`agent-profile` manages profiles — everything under
[Commands](#commands) below. `claude` is Claude Code itself, with a wrapper in
front that points `CLAUDE_CONFIG_DIR` at whichever profile is active. One to
choose, one to work.

Launching is the half that has to work everywhere, and how far the wrapper
reaches depends on where you are:

| context | `agent-profile` | `claude` follows the active profile |
|---|---|---|
| interactive zsh or bash | yes, function and symlink on PATH | yes, shell function |
| `zsh -c`, zsh scripts, Claude Code's own Bash tool | yes, symlink on PATH | yes, via the `.zshenv` shim |
| `bash -c` | yes, symlink on PATH | no — would need `BASH_ENV`, out of scope |
| `sh -c`, cron, GUI-launched apps | yes, symlink on PATH | no |

`agent-profile` is reachable two ways on purpose: sourcing your rc defines it as
a shell function, and `install.sh` also symlinks it into `~/.local/bin`. Either
would do in most setups — both, because `~/.local/bin` is absent from the default
PATH on macOS, and a login shell does not always read the file the source line
went into. Where the `claude` wrapper does not reach, a session still gets the
right config through `agent-profile <name> -- <args>`.

Pass `--no-shim` to skip installing the standalone `claude` wrapper if you only
want `agent-profile`; you still get the `claude` shell function in an interactive
shell either way, since that comes from sourcing your rc, not from the shim.

### Moving off an old clone

Profiles used to live inside the clone itself, at
`~/agent-profiles/profiles/`. They now default to `~/.agent-profiles`
(plural, outside any clone — see [Where the data
lives](#where-the-data-lives)), so moving to this version needs a one-time
migration:

```sh
agent-profile --migrate-store ~/agent-profiles
```

This moves `profiles/`, `active`, `exports/`, `.backups/` and
`prompt-state.json` out of the old clone and rewrites the absolute paths a
profile bakes into its own `settings.json`, `settings.local.json`,
`statusline.sh` and hooks so they still point at the right place;
`.claude.json` and `teams/*/config.json` are left alone, since those hold
project history for the clone directory, which still exists.
`install.sh`, run from a clone that still has its own `profiles/` directory,
does this automatically — pass `--no-migrate` to skip it.

**A migration with nothing to rewrite still exits 1.** If none of your
profiles have an absolute clone path baked into `settings.json` — true for
anything only ever `--create`d and never customized — the files move
correctly, but the command's own `store is now ...` success line never
prints, and if `install.sh` triggered it automatically you'll see the
worrying `the code is installed but the store was not migrated` message even
though it was. Check `~/.agent-profiles/profiles/` (or your
`CLAUDE_PROFILES_DIR`) before re-running anything by hand — the data has
already moved.

### Without installing

`agent-profile` is a command this repo adds, not something Claude Code ships.
Skip the install and there is nothing to run:

```
agent-profile: command not found
```

Running the script directly needs no install at all:

```sh
./agent-profile.sh --create development
./agent-profile.sh development
./agent-profile.sh development -- --version
```

Every subcommand works this way. What you give up is the shadowing: a bare
`claude` reads `~/.claude` no matter which profile is active, because only a
function already in your shell can change that. Start sessions with
`./agent-profile.sh <name> -- <args>` instead. The old
`./claude-profile.sh` entry point remains as a compatibility shim.

### Windows

The wrapper is a POSIX shell function and exists only inside the shell that
sourced it, so `install.sh` covers Git Bash and nothing else. PowerShell needs
its own install, which defines the same two commands natively — `claude` as a
function, `agent-profile` as an alias:

```powershell
.\install.ps1
```

Both can be installed at once, and should be if you use both. They are meant
to share one store, so that a profile created in either is visible in both —
but that is **not currently true**. Only the Git Bash / `install.sh` half
defaults to `~/.agent-profiles`; `install.ps1`'s store still defaults to its
own module directory. Left on defaults, the two halves read two different
stores and `agent-profile` lists different profiles depending on which one
you're in. Until the PowerShell half is migrated too, set
`CLAUDE_PROFILES_DIR` explicitly, to the same path, for both — and install
from a git clone with `install.ps1`; `npm i -g agent-profiles` on Windows
does not run it (see [Install](#install)).

`install.ps1` edits `$PROFILE`, checks that a fresh PowerShell really does end
up with both commands defined, and warns if your execution policy is
`Restricted` or `AllSigned` — under those, PowerShell never reads your profile
and the wrapper is never defined. It will not change the policy for you; the fix
is `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

`agent-profile` is an alias rather than a function because PowerShell reads any
hyphenated name as `Verb-Noun` and warns on import when the verb is not one of its
approved ones — which "claude" will never be. Aliases are not verb-checked, so
this is the spelling that does not print a warning every time you open a shell.
`Get-Command agent-profile` reports it as an `Alias` for `Invoke-CpProfile`;
both names work.

Only two things are reimplemented in PowerShell: working out which profile is
selected, and starting `claude.exe` with `CLAUDE_CONFIG_DIR` set. Every
management subcommand is handed to `agent-profile.sh` under Git Bash, so Git
for Windows is a requirement for those — switching and launching work without
it. If Git is somewhere unusual, point `$env:CLAUDE_PROFILE_BASH` at
`bash.exe`. Do not point it at the `bash.exe` on `PATH` if you have WSL
installed: that is a different operating system with a different `$HOME`, and it
would quietly operate on a different store.

One syntax difference, forced by the PowerShell parser: it treats a bare `--` as
end-of-parameters and eats it before the function is called, so

```powershell
agent-profile finance -- --version
```

arrives as `finance --version`, with the separator already gone. It works
anyway — a profile name followed by any arguments at all is read as "run one
session in that profile", since the plain setter takes exactly one argument.
Quoting it (`'--'`) also works if you prefer to keep the two platforms looking
identical.

**cmd.exe is not supported** and cannot be: it has no mechanism for shadowing an
executable with a function. **WSL is a separate installation** — its `$HOME` and
filesystem are its own, so clone the repo inside WSL and run `install.sh` there
if you want profiles in WSL too.

See [Uninstall](#uninstall) for removing either half.

## Commands

| Command | Does |
|---|---|
| `agent-profile` | Active profile, why it was selected, and the full list |
| `agent-profile <name>` | Set the active profile |
| `agent-profile default` | Clear it; back to plain `~/.claude` |
| `agent-profile <name> -- <args>` | One session in `<name>`; active unchanged |
| `agent-profile --create <name>` | Snapshot the current Claude and Codex setup |
| `agent-profile --update <name>` | Mirror the current Claude and Codex setup into `<name>` |
| `agent-profile --reset [name]` | Wipe `<name>` (default: active) back to a first-run config; old contents moved to `.backups/`. Shared paths stay linked, so you stay logged in |
| `agent-profile --delete <name>` | Delete (moved to `.backups/`) |
| `agent-profile --rename <a> <b>` | Rename |
| `agent-profile --copy <a> <b>` | Duplicate |
| `agent-profile --show [name]` | Path, model, plugins, skills, hooks, MCP servers. No name: the profile you're in right now |
| `agent-profile --diff <a> <b>` | The same, side by side |
| `agent-profile --path [name]` | Print where that profile's config directory is, and nothing else |
| `agent-profile --open [name]` | Open that directory in Explorer / Finder / your file manager |
| `agent-profile --export <name> [file]` | Shareable tarball into `exports/` (override with `file`), excludes `.credentials.json` (see Security notes) |
| `agent-profile --import <file> [name]` | Create a profile from a tarball |

## Which profile am I in?

Most specific wins:

1. `CLAUDE_PROFILE=finance claude` — one invocation
2. A `.claude-profile` file containing a profile name, found walking up from
   the current directory
3. The active profile (`agent-profile <name>`)
4. `~/.claude`

The environment variable and project pin are Claude-only session overrides.
Codex follows the globally active profile because its desktop app cannot read a
shell-local override.

`agent-profile` tells you which of these fired. `agent-profile --show` answers
the same question and then describes what you'd actually be running with:

```
$ agent-profile --show
dev  (active)
  path     /home/you/.agent-profiles/profiles/dev
  model    opus-5
  plugins  superpowers@obra
  skills   research, writing
  hooks    3
  mcp      figma, linear
```

## Where do profiles live?

Under `<store>/profiles/<name>`, where the store is `~/.agent-profiles` unless
`$CLAUDE_PROFILES_DIR` says otherwise. Two commands save you working that out:

```sh
agent-profile --path            # the directory you're using right now
agent-profile --path finance    # a specific profile's
agent-profile --open finance    # the same, in your file manager
cd "$(agent-profile --path)"    # --path prints the path alone, for this
```

On Windows these print `C:\...` from PowerShell and `/c/...` from Git Bash —
each shell gets the spelling it can actually use.

## Shared vs per-profile

Per-profile (copied): everything not on the shared list below — `settings.json`,
`CLAUDE.md`, `skills/`, `commands/`, `hooks/`, `agents/`, `scripts/`,
`statusline.sh`, `.claude.json`, and anything else sitting in `~/.claude`
(`.caveman-active`, `teams/`, `agentic-os/`, whatever a future Claude Code
version adds), plus `codex.config.toml`. It's copy-the-rest, not an allowlist, so
nothing here needs updating when Claude Code grows a new config file.

Shared across all profiles (symlinked back to `~/.claude`): `plugins/` (the
download cache — install once, enable per profile in `settings.json`),
`projects/`, `history.jsonl`, `.credentials.json` (so you never re-authenticate),
and the runtime directories.

## Where the data lives

Profiles and the preserved default Codex config live in `~/.agent-profiles`
by default — outside any clone, so a clone can be deleted or moved without
losing them. `profiles/` holds the profiles themselves, `active` the active
profile name, `.backups/` the pre-update snapshots. Set `CLAUDE_PROFILES_DIR`
to put the store somewhere else instead. If you point it at a git-tracked
directory anyway — including this clone's own, pre-migration — `profiles/`,
`active`, `.backups/`, `exports/`, `prompt-state.json` and
`codex-default.config.toml` are all in this repo's `.gitignore`, so a profile's
`settings.json` and any API keys in it were never at risk of being committed.
Upgrading from a version that kept `profiles/` inside the clone? See
[Moving off an old clone](#moving-off-an-old-clone).

`.backups/` has no retention policy — nothing prunes it automatically. On a
long-lived install it grows without bound; clear old entries by hand if that
becomes a problem.

## Security notes

**`--export` can leak secrets that aren't credentials.** The tarball
structurally excludes `.credentials.json`, but `settings.json` and
`codex.config.toml` are included. Anything you've put in an environment block,
MCP config or hook command travels with the archive. The tool warns when it
sees a top-level `env` key and prints the manifest of what's inside — read that
manifest before you send the file to anyone. **The warning itself needs Python**: without it the
check silently fails and no warning is printed, so on a machine with no
`python3`, `python` or `py` you must read the manifest yourself instead of
trusting the absence of a warning.

**Import's path-traversal safety relies on the `tar` binary refusing to
extract `../` entries**, which is true of bsdtar and modern GNU tar. It has
not been verified against older GNU tar builds.

**Import rewrites any `/profiles/` path segment it finds in `settings.json`**,
not just the exporter's own store path — if a hook or `env` value legitimately
points somewhere containing a literal `/profiles/` directory unrelated to
agent-profile, that path gets rewritten too.

## Recovering from a bad `--update` or `--delete`

There is no `--restore` command. Both commands move the profile's previous
contents to `.backups/<name>-<timestamp>/` before writing, so recovery is a
manual copy:

`agent-profile` prints a `store: <path>` line — that's the directory below.
Substitute it for `<store>`:

```sh
ls <store>/.backups/                          # find the timestamp
rm -rf <store>/profiles/<name>                # or wherever it landed
cp -R <store>/.backups/<name>-<timestamp> <store>/profiles/<name>
```

`<store>` is `~/.agent-profiles` by default, or `$CLAUDE_PROFILES_DIR` if you set it —
which is exactly why the status output names it rather than making you guess.

## Statusline

Want the active profile in your statusline? Append this to your
`statusline.sh` by hand:

```sh
if [ -z "$CLAUDE_CONFIG_DIR" ] || [ "$CLAUDE_CONFIG_DIR" = "$HOME/.claude" ]; then
    printf ' · [default]'
else
    printf ' · [%s]' "${CLAUDE_CONFIG_DIR##*/}"
fi
```

It names the config the session is actually running on: the profile name when
one is active, `[default]` on base `~/.claude`. It always prints — a blank
statusline would be ambiguous between "on base" and "not installed".

Which `statusline.sh` matters: Claude Code reads `$CLAUDE_CONFIG_DIR`, so while
a profile is active it runs *that profile's* copy, not the base one. Add the
snippet to `<store>/profiles/<name>/statusline.sh` for the profiles you want it
in, and to `~/.claude/statusline.sh` so future profiles inherit it. (This is
why there's no `--install-statusline` command: a single write to base would
silently miss every profile that already exists.)

## Uninstall

Run `./install.sh --uninstall` from the clone. It removes the rc source line, the
`.zshenv` PATH block, the `agent-profile` symlink, and the install directory
(`~/.agent-profile` by default), and prints where your profile store still
lives — nothing under it is touched. Installed via npm? Use
`agent-profile-install --uninstall` instead — it runs the same `install.sh`,
kept inside the npm package after a git clone would be gone.

There's no equivalent on the PowerShell side yet: remove the `Import-Module`
line from `$PROFILE` and the `source` line from your shell rc by hand.

`~/.claude` is untouched throughout — this tool never writes to it.

## Requirements

POSIX sh (zsh or bash) and `tar`. Python is used by `--show`, `--diff`, and the
`--export` env-block warning. Whichever of `python3`, `python` or `py -3` runs
first is used; without any of them `--show`/`--diff` print the profile's path,
then say which commands were looked for and exit 127, and `--export` skips the
warning silently and still produces the archive — see Security notes. `--path`
and `--open` need no Python at all.

Each candidate is probed by running it, not by looking for it on `PATH`. On
Windows `python3` is usually the Microsoft Store's App Execution Alias — a stub
that is on `PATH` and passes a `command -v` check, then prints "Python was not
found; run without arguments to install from the Microsoft Store" to stderr and
exits 49 without running anything. Probing steps over it to the real `python`
or `py` next to it.

On Windows, additionally: Windows PowerShell 5.1 or later for `install.ps1`, and
Git for Windows for the management subcommands.

## Tests

```sh
zsh test.sh && bash test.sh && sh test.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File .\test.ps1
```

Tests run against a temporary store and a temporary fake home. They never read
or write your real `~/.claude` or `~/.codex`.

`test.ps1` ends with a drift guard. Profile resolution is the one piece of logic
that exists twice — `lib/resolve.sh` and `agent-profile.psm1` — so rather than
checking the PowerShell version against hardcoded expectations, it runs both
against the same temporary store and fails if they disagree. It skips itself
with a printed note when Git Bash is not installed.

Verified on Claude Code 2.1.220: `--create` against a real `~/.claude` (552K,
symlinks resolved, `settings.json` rewritten), and
`CLAUDE_CONFIG_DIR=.../profiles/smoke claude --version` loaded it cleanly.
