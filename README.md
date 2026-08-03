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
| `claude profile --export <name> [file]` | Shareable tarball, excludes `.credentials.json` (see Security notes) |
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

Remove the `source` line from your shell rc, run
`claude profile --uninstall-statusline` if you installed it, and delete the
clone. `~/.claude` is untouched throughout — this tool never writes to it,
except for the opt-in statusline block.

## Requirements

POSIX sh (zsh or bash) and `tar`. `python3` is used by `--show`, `--diff`, and
the `--export` env-block warning. Without it, `--show`/`--diff` print the
profile name and then a bare `command not found` (exit 127); `--export` just
skips the warning silently and still produces the archive — see Security
notes.

## Tests

```sh
zsh test.sh && bash test.sh && sh test.sh
```

Tests run against a temporary store and a temporary fake home. They never read
or write your real `~/.claude`.

Verified on Claude Code 2.1.220: `--create` against a real `~/.claude` (552K,
symlinks resolved, `settings.json` rewritten), and
`CLAUDE_CONFIG_DIR=.../profiles/smoke claude --version` loaded it cleanly.
