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

Per-profile (copied): `settings.json`, `CLAUDE.md`, `skills/`, `commands/`,
`hooks/`, `agents/`, `scripts/`, `statusline.sh`, `.claude.json`.

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
the file to anyone.

**Import's path-traversal safety relies on the `tar` binary refusing to
extract `../` entries**, which is true of bsdtar and modern GNU tar. It has
not been verified against older GNU tar builds.

## Recovering from a bad `--update` or `--delete`

There is no `--restore` command. Both commands move the profile's previous
contents to `.backups/<name>-<timestamp>/` before writing, so recovery is a
manual copy:

```sh
ls "$(claude profile)/../.backups/"                       # find the timestamp
rm -rf ~/claude-profiles/profiles/<name>                  # or wherever it landed
cp -R ~/claude-profiles/.backups/<name>-<timestamp> ~/claude-profiles/profiles/<name>
```

(Adjust the store path if you've set `CLAUDE_PROFILES_DIR`.)

## Uninstall

Remove the `source` line from your shell rc, run
`claude profile --uninstall-statusline` if you installed it, and delete the
clone. `~/.claude` is untouched throughout — this tool never writes to it,
except for the opt-in statusline block.

## Requirements

POSIX sh (zsh or bash) and `tar`. `python3` is needed only for `--show` and
`--diff` — without it, everything else works fine, but those two commands
print the profile name and then a bare `command not found` (exit 127).

## Tests

```sh
sh test.sh && bash test.sh
```

Tests run against a temporary store and a temporary fake home. They never read
or write your real `~/.claude`.
