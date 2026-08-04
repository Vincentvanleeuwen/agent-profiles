### Merge verdict

**Ready with the three listed Important fixes.** No Critical findings. Nothing here
loses data or breaks a user of the POSIX path.

CONTROLLER-PERFORMED REVIEW. The subagent dispatch for this review was blocked by the
permission classifier five times, including retries after the user opted to allow it.
This is a real review — the controller did not write any of the code — but it is not
independent of the person who wrote the plan and directed the fix rounds, which is
exactly the perspective an outside reviewer would have supplied. If the permission is
resolved, re-run it; the package is at review-c76a30f..7561287.diff.

### What's solid

- **The store/install-dir distinction holds everywhere.** `$HOME/.claude-profiles`
  (data) and `$HOME/.claude-profile` (code) differ by one character, and a sweep of
  `install.sh`, `lib/`, `bin/claude` and `scripts/` found no conflation — the only
  bare `claude-profiles` strings are the npm package name in log messages
  (`scripts/postinstall.mjs:10,22`).
- **Both `rm -rf` paths share one guard, and that is documented at the second site.**
  `install.sh:294` (`copy_code`'s per-item wipe, additionally `${INSTALL_DIR:?}`) and
  `install.sh:280` (`--uninstall`'s tree removal) both rely on the canonicalizing
  check at `install.sh:27-43`, and `install.sh:268` says so explicitly rather than
  leaving the next reader to wonder whether a guard was forgotten. That guard resolves
  with `pwd -P` and refuses `/`, exact `$HOME`, and any ancestor of `$HOME`.
- **358 passing assertions**, up from ~200, with the suite's two failures unchanged
  from upstream — so the branch added substantial coverage without touching the
  inherited red.
- **Three separate defects of the form "test passes for the wrong reason" were found
  and fixed with sensitivity proofs** (revert the fix, watch the test fail): the npm
  symlink repair, the migrate exit-code leak, and the `|| true` masking at the
  clone-migration fixture. That discipline is the most valuable thing in this branch.
- **Failure messages state what already succeeded.** Every `die` in the install
  sequence now says which steps completed, so a user who hits one knows whether their
  machine is half-configured. That came out of review, not the plan.
- **Windows is documented honestly rather than papered over** (`README.md:36-38`, plus
  a dedicated section at `README.md:160`), including that `npm i -g` prints a message
  instead of running the unmigrated installer.

### Findings

#### Critical (blocks merge)

None.

#### Important (should fix before merge)

1. **Four fixture-variable collisions in `test.sh`, all introduced by Task 5.**
   `IH` (`test.sh:825` `ihome-stable` vs `:985` `ihome`), `IH2` (`:900` vs `:990`),
   `IH3` (`:911` vs `:996`), `IH4` (`:923` `ihome-migrate` vs `:1002` `ihome4`). Each
   works today only because the first fixture is fully consumed before the second
   reassigns the name. Inserting or reordering a fixture between them would silently
   repoint an existing test at the wrong home — and the failure would look like a bug
   in the code under test, not in the fixture. Fix: rename Task 5's four to distinct
   names (`IH_STABLE`, `IH_OLDLINE`, `IH_NOSHIM`, `IH_MIGRATE` or similar). Mechanical.

2. **The reason `bin/claude-profile` must remain a symlink is recorded nowhere a
   maintainer will find it.** `bin/claude` is a real script; `bin/claude-profile` is a
   symlink. That asymmetry looks like an inconsistency and invites "tidying" into a
   wrapper — which would break Surface A, because `link_bin` always points
   `$LINK_DIR/claude-profile` at `$BIN_DIR/claude-profile`, so a `dirname "$0"` wrapper
   would resolve `../claude-profile.sh` against `$LINK_DIR` instead of `$BIN_DIR`.
   `bin/claude:3` carries a note about symlinking *itself*, which is a different point.
   Fix: one comment at `install.sh:302`, where the symlink is created, stating why it
   is a symlink and not a script.

3. **No coverage for reinstall after uninstall.** The suite tests install idempotency
   and uninstall idempotency separately, but never install → uninstall → install. That
   is the sequence a user hits when they change their mind or move machines, and it is
   where leftover state would surface (a stale `.zshenv` block, a removed rc line that
   isn't re-added, an install dir that was deleted while its symlink survived). One
   fixture, three assertions.

#### Minor (can carry)

- The suite is not zsh-clean and this branch made it worse: upstream sh=2/bash=4/zsh=6,
  branch sh=2/bash=4/zsh=40. Cause is zsh not word-splitting unquoted parameters, so
  the `env $XENV` fixture idiom degrades. `test.sh` is `#!/bin/sh`, the documented
  runner is `sh test.sh`, and zsh was never green upstream — so this is a limitation,
  not a regression in supported usage. Fixing it means rewriting ~34 fixtures.
- ~65 lines still end in `>/dev/null 2>&1` without asserting an exit status. Most are
  legitimate (the side effect is asserted separately on the next line), but the pattern
  is what hid the migrate bug, so it deserves a pass at some point — not now.

### Deferred-item triage

- **Windows: two halves would read different stores** (`claude-profile.psm1:42-45`
  still returns `$script:CpRoot`). **Carry.** Dropped deliberately by the user, and
  documented where a Windows user will see it before following macOS instructions. It
  is a genuine footgun for a Windows user who uses both halves, so it should be the
  first item of any follow-up branch — but it does not block a POSIX-only merge.
- **`hooks/*` glob is non-recursive** — carry. Verified nothing in the codebase creates
  nested hooks.
- **A symlinked hook is replaced by a plain file on migration** — carry. Silent
  structural change, no data loss, no current user hits it.
- **`sed` cannot distinguish a functional path from the same string in a log message
  inside a profile-owned file** — carry. Scope already narrowed to four file patterns.
- **A literal newline in a store path breaks the single-line `sed`** — carry. Nothing
  else in the codebase handles that either.
- **Interrupted-migration heuristic fires on any of the five entry names existing at
  the destination** — carry. Best-effort signal by design, and the alternative is a
  transaction log.
- **Dangling *foreign* symlink at `$LINK_DIR/claude-profile` is left alone but not
  reported**, because `-e` follows the link — carry, cosmetic.
- **`--uninstall` on a machine with no rc file creates an empty one** — carry. Odd, harmless.
- **`manual()`'s install-oriented wording on an ambiguous-shell uninstall** — carry, cosmetic.
- **No coverage for uninstall on a never-installed machine** — carry, but pair it with
  Important 3 if you write that fixture anyway; the two share a harness.
- **`test.sh:915` is the only `install.sh` invocation without an explicit `HOME`
  override**, relying on the suite-wide export — **fix with Important 1**, since it is
  the same class of implicit-fixture-state problem and the file is being touched anyway.

### Assessment

The branch does what the spec set out to do on POSIX: both PATH surfaces work, the
store survives an npm upgrade and a node version change, migration rewrites the paths
profiles baked into themselves, and uninstall reverses an install without touching user
data. Its strongest feature is that the riskiest code paths — two `rm -rf` sites, a
directory move, a config rewrite — are guarded by one canonicalizing check and covered
by tests that have each been observed failing without their fix. The three Important
findings are all in test hygiene and documentation rather than behaviour, and none is
more than a few minutes' work.
