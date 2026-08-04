# Claude Profiles

Switch Claude Code between named configuration profiles — different enabled
plugins, skills, commands, hooks, MCP servers, model and permissions per
profile — without editing `~/.claude` by hand.

A profile is a complete `CLAUDE_CONFIG_DIR`. Claude Code honours that variable
natively, so switching is just pointing it somewhere else.

## Install

```sh
git clone <this repo> ~/claude-profiles
~/claude-profiles/install.sh
```

On Windows, run `.\install.ps1` from PowerShell instead — or as well, if you use
both PowerShell and Git Bash. See [Windows](#windows).

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

An existing line pointing at a different clone also stops it. Nothing gets
edited in either case.

Start a new shell, then snapshot your current setup:

```sh
claude profile --create development
claude profile development
```

`claude` now runs with that profile. `claude profile default` goes back to
plain `~/.claude`.

### Without installing

`claude profile ...` is not a Claude Code subcommand. It works because sourcing
`claude-profile.sh` defines a shell function named `claude` that intercepts it.
Skip that step and the arguments reach Claude Code itself, which replies

```
error: unknown option '--create'
```

Running the script directly needs no install at all:

```sh
./claude-profile.sh --create development
./claude-profile.sh development
./claude-profile.sh development -- --version
```

Every subcommand works this way. What you give up is the shadowing: a bare
`claude` reads `~/.claude` no matter which profile is active, because only a
function already in your shell can change that. Start sessions with
`./claude-profile.sh <name> -- <args>` instead.

### Windows

The wrapper is a POSIX shell function and exists only inside the shell that
sourced it, so `install.sh` covers Git Bash and nothing else. PowerShell needs
its own install, which defines the same `claude` command as a PowerShell
function:

```powershell
.\install.ps1
```

Both can be installed at once, and should be if you use both. They share one
store, so a profile created in either is visible in both and `claude profile
<name>` in one switches the other.

`install.ps1` edits `$PROFILE`, checks that a fresh PowerShell really does end
up with `claude` as a function, and warns if your execution policy is
`Restricted` or `AllSigned` — under those, PowerShell never reads your profile
and the wrapper is never defined. It will not change the policy for you; the fix
is `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

Only two things are reimplemented in PowerShell: working out which profile is
selected, and starting `claude.exe` with `CLAUDE_CONFIG_DIR` set. Every
management subcommand is handed to `claude-profile.sh` under Git Bash, so Git
for Windows is a requirement for those — switching and launching work without
it. If Git is somewhere unusual, point `$env:CLAUDE_PROFILE_BASH` at
`bash.exe`. Do not point it at the `bash.exe` on `PATH` if you have WSL
installed: that is a different operating system with a different `$HOME`, and it
would quietly operate on a different store.

One syntax difference, forced by the PowerShell parser: it treats a bare `--` as
end-of-parameters and eats it before the function is called, so

```powershell
claude profile finance -- --version
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

Uninstalling is the mirror image: delete the `Import-Module` line from
`$PROFILE`, and the `source` line from your shell rc.

## Commands

| Command | Does |
|---|---|
| `claude profile` | Active profile, why it was selected, and the full list |
| `claude profile <name>` | Set the active profile |
| `claude profile default` | Clear it; back to plain `~/.claude` |
| `claude profile <name> -- <args>` | One session in `<name>`; active unchanged |
| `claude profile --create <name>` | Snapshot the current setup |
| `claude profile --update <name>` | Mirror the current setup into `<name>` |
| `claude profile --reset [name]` | Wipe `<name>` (default: active) back to a first-run config; old contents moved to `.backups/`. Shared paths stay linked, so you stay logged in |
| `claude profile --delete <name>` | Delete (moved to `.backups/`) |
| `claude profile --rename <a> <b>` | Rename |
| `claude profile --copy <a> <b>` | Duplicate |
| `claude profile --show <name>` | Model, plugins, skills, hooks, MCP servers |
| `claude profile --diff <a> <b>` | The same, side by side |
| `claude profile --export <name> [file]` | Shareable tarball into `exports/` (override with `file`), excludes `.credentials.json` (see Security notes) |
| `claude profile --import <file> [name]` | Create a profile from a tarball |
| `claude profile --install-statusline` | Show the running profile (or `default`) in your statusline |
| `claude profile --uninstall-statusline` | Remove it |

## Which profile am I in?

Most specific wins:

1. `CLAUDE_PROFILE=finance claude` — one invocation
2. A `.claude-profile` file containing a profile name, found walking up from
   the current directory
3. The active profile (`claude profile <name>`)
4. `~/.claude`

`claude profile` tells you which of these fired.

## Shared vs per-profile

Per-profile (copied): everything not on the shared list below — `settings.json`,
`CLAUDE.md`, `skills/`, `commands/`, `hooks/`, `agents/`, `scripts/`,
`statusline.sh`, `.claude.json`, and anything else sitting in `~/.claude`
(`.caveman-active`, `teams/`, `agentic-os/`, whatever a future Claude Code
version adds). It's copy-the-rest, not an allowlist, so nothing here needs
updating when Claude Code grows a new config file.

Shared across all profiles (symlinked back to `~/.claude`): `plugins/` (the
download cache — install once, enable per profile in `settings.json`),
`projects/`, `history.jsonl`, `.credentials.json` (so you never re-authenticate),
and the runtime directories.

## Where the data lives

Profiles live in `profiles/` inside this clone, with the active profile name in
`active` and pre-update snapshots in `.backups/`. **All three are in
`.gitignore` and must stay there.** A profile's `settings.json` can hold
environment variables and API keys — that's the whole reason they're
gitignored, not an oversight, so don't "fix" it. Set `CLAUDE_PROFILES_DIR` to
keep them elsewhere.

`.backups/` has no retention policy — nothing prunes it automatically. On a
long-lived install it grows without bound; clear old entries by hand if that
becomes a problem.

## Security notes

**`--export` can leak secrets that aren't credentials.** The tarball
structurally excludes `.credentials.json`, but `settings.json` is included,
and anything you've put in its `env` block or baked into a hook command
travels with the archive. The tool warns when it sees a top-level `env` key
and prints the manifest of what's inside — read that manifest before you send
the file to anyone. **The warning itself needs `python3`**: without it the
check silently fails and no warning is printed, so on a machine without
`python3` you must read the manifest yourself instead of trusting the absence
of a warning.

**Import's path-traversal safety relies on the `tar` binary refusing to
extract `../` entries**, which is true of bsdtar and modern GNU tar. It has
not been verified against older GNU tar builds.

**Import rewrites any `/profiles/` path segment it finds in `settings.json`**,
not just the exporter's own store path — if a hook or `env` value legitimately
points somewhere containing a literal `/profiles/` directory unrelated to
claude-profile, that path gets rewritten too.

## Recovering from a bad `--update` or `--delete`

There is no `--restore` command. Both commands move the profile's previous
contents to `.backups/<name>-<timestamp>/` before writing, so recovery is a
manual copy:

`claude profile` prints a `store: <path>` line — that's the directory below.
Substitute it for `<store>`:

```sh
ls <store>/.backups/                          # find the timestamp
rm -rf <store>/profiles/<name>                # or wherever it landed
cp -R <store>/.backups/<name>-<timestamp> <store>/profiles/<name>
```

`<store>` is `~/claude-profiles` by default, or `$CLAUDE_PROFILES_DIR` if you set it —
which is exactly why the status output names it rather than making you guess.

## Statusline

The block appends ` · [<name>]` to your statusline, naming the config the
session is actually running on: the profile name when one is active, and
`[default]` when you are on the base `~/.claude`. It always prints — a blank
statusline would be ambiguous between "on base" and "block not installed".

`--install-statusline` edits `~/.claude/statusline.sh` (base), not any
existing profile. Profiles created *after* installing inherit the block
through the normal copy; profiles that already existed at install time don't
get it until you `--update` them — `--update` mirrors from base, so it picks
up the block same as any other change.

## Uninstall

Remove the `source` line from your shell rc and the `Import-Module` line from
`$PROFILE` if you installed the PowerShell side, run
`claude profile --uninstall-statusline` if you installed it, and delete the
clone. `~/.claude` is untouched throughout — this tool never writes to it,
except for the opt-in statusline block.

## Requirements

POSIX sh (zsh or bash) and `tar`. `python3` is used by `--show`, `--diff`, and
the `--export` env-block warning. Without it, `--show`/`--diff` print the
profile name and then a bare `command not found` (exit 127); `--export` just
skips the warning silently and still produces the archive — see Security
notes.

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
or write your real `~/.claude`.

`test.ps1` ends with a drift guard. Profile resolution is the one piece of logic
that exists twice — `lib/resolve.sh` and `claude-profile.psm1` — so rather than
checking the PowerShell version against hardcoded expectations, it runs both
against the same temporary store and fails if they disagree. It skips itself
with a printed note when Git Bash is not installed.

Verified on Claude Code 2.1.220: `--create` against a real `~/.claude` (552K,
symlinks resolved, `settings.json` rewritten), and
`CLAUDE_CONFIG_DIR=.../profiles/smoke claude --version` loaded it cleanly.
