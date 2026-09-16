# Fresh-install CI Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the published npm tarball and clone installers work from disposable homes on native Linux, macOS, and Windows runners.

**Architecture:** Keep the existing unit suites intact and add two black-box smoke scripts: POSIX installs the packed npm artifact, while PowerShell follows the documented Windows clone flow. A GitHub Actions build job creates one tarball, then native OS jobs consume that artifact so packaging and installation are tested separately.

**Tech Stack:** POSIX sh, Windows PowerShell 5.1/PowerShell 7, Node.js 24, npm, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-09-16-cross-platform-install-validation-design.md`

## Global Constraints

- Every smoke test uses a disposable `HOME`, profile store, install directory, shell rc, and npm prefix.
- No test reads or writes the runner account's real Claude, Codex, or Agent Profiles state.
- The POSIX smoke test installs the `.tgz` artifact, never the checkout.
- Windows npm installation remains an asserted guidance path; the supported fresh install is `install.ps1` from a clone.
- No authenticated AI calls, provider processes, downloaded models, new npm dependencies, custom VM images, or Docker substitutes for native runners.
- Canonical commands are `agent-profile` and `agent-profile-install`; `claude-profile` remains a compatibility assertion.

---

## File structure

- Create `test/fresh-install.sh`: black-box npm-tarball journey for macOS/Linux.
- Create `test/fresh-install.ps1`: black-box clone/install-module journey for Windows.
- Create `.github/workflows/test.yml`: package-once and native-runner CI matrix.
- Modify `test.sh`: assert both smoke entry points ship in the checkout and parse.
- Modify `test.ps1`: assert the PowerShell smoke entry point parses.
- Modify `package.json`: expose local commands for the two smoke tests without adding dependencies.
- Modify `README.md`: document the automated fresh-install commands and tested matrix.

### Task 1: POSIX packed-package smoke journey

**Files:**
- Create: `test/fresh-install.sh`
- Modify: `test.sh`
- Modify: `package.json`

**Interfaces:**
- Consumes: optional first argument containing an existing absolute `.tgz` path.
- Produces: `sh test/fresh-install.sh [package.tgz]`, exit `0` only after install/create/activate/default/uninstall succeeds.

- [ ] **Step 1: Add the failing entry-point assertions**

Append to the packaging section of `test.sh`:

```sh
check "fresh POSIX package smoke exists" '[ -x "$HERE/test/fresh-install.sh" ]'
check "fresh POSIX package smoke parses" 'sh -n "$HERE/test/fresh-install.sh"'
check_with "fresh POSIX npm script is wired" node \
  'node -e "const p=require(\"$HERE/package.json\"); if (p.scripts[\"test:fresh:posix\"] !== \"sh test/fresh-install.sh\") process.exit(1)"'
```

- [ ] **Step 2: Run the focused suite and verify red**

Run: `npm test`

Expected: failures named `fresh POSIX package smoke exists`, `fresh POSIX package smoke parses`, and `fresh POSIX npm script is wired`.

- [ ] **Step 3: Implement the smoke script**

Create an executable `test/fresh-install.sh` using only POSIX utilities. It must:

```sh
#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-profiles-fresh.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

if [ "$#" -gt 0 ]; then
    PACKAGE=$1
else
    npm pack "$ROOT" --pack-destination "$TMP_ROOT" >/dev/null
    set -- "$TMP_ROOT"/agent-profiles-*.tgz
    [ -f "$1" ] || { printf 'fresh-install: npm pack produced no tarball\n' >&2; exit 1; }
    PACKAGE=$1
fi

case "$PACKAGE" in /*) ;; *) PACKAGE="$(cd "$(dirname "$PACKAGE")" && pwd)/$(basename "$PACKAGE")" ;; esac

FAKE_HOME="$TMP_ROOT/home"
STORE="$FAKE_HOME/.agent-profiles"
INSTALL="$FAKE_HOME/.agent-profile"
PREFIX="$TMP_ROOT/npm-prefix"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.codex" "$PREFIX"
printf '{"model":"default-marker"}\n' > "$FAKE_HOME/.claude/settings.json"
printf 'model = "default-marker"\n' > "$FAKE_HOME/.codex/config.toml"

run_env() {
    env HOME="$FAKE_HOME" CLAUDE_PROFILES_DIR="$STORE" \
        CLAUDE_PROFILE_INSTALL_DIR="$INSTALL" CP_RC="$FAKE_HOME/.zshrc" \
        CP_ZSHENV="$FAKE_HOME/.zshenv" CP_LINK_DIR="$FAKE_HOME/.local/bin" \
        SHELL=/bin/zsh PATH="$FAKE_HOME/.local/bin:$PREFIX/bin:$PATH" "$@"
}

run_env npm install --global --prefix "$PREFIX" "$PACKAGE"
run_env agent-profile --create fresh
run_env agent-profile fresh
[ "$(cat "$STORE/active")" = fresh ]
[ "$(readlink "$FAKE_HOME/.codex/config.toml")" = "$STORE/profiles/fresh/codex.config.toml" ]
run_env agent-profile default
[ ! -e "$STORE/active" ]
grep -q 'default-marker' "$FAKE_HOME/.codex/config.toml"
run_env agent-profile-install --uninstall
[ ! -e "$INSTALL" ]
[ -d "$STORE/profiles/fresh" ]
printf 'fresh POSIX package install passed\n'
```

Add to `package.json`:

```json
"test:fresh:posix": "sh test/fresh-install.sh"
```

- [ ] **Step 4: Run the smoke and full suite**

Run: `npm run test:fresh:posix`

Expected: `fresh POSIX package install passed`.

Run: `npm test`

Expected: `all passed`.

- [ ] **Step 5: Commit**

```bash
git add test/fresh-install.sh test.sh package.json
git commit -m "test: add packed-package install smoke"
```

### Task 2: Windows clone-install smoke journey

**Files:**
- Create: `test/fresh-install.ps1`
- Modify: `test.ps1`
- Modify: `package.json`

**Interfaces:**
- Consumes: the current checkout and Git for Windows when management commands are exercised.
- Produces: `powershell -ExecutionPolicy Bypass -File test/fresh-install.ps1`, exit `0` after a clean PowerShell profile loads both exported surfaces.

- [ ] **Step 1: Add the failing entry-point assertions**

Before the scratch-fixture block in `test.ps1`, add:

```powershell
$freshInstall = Join-Path $selfDir 'test\fresh-install.ps1'
Check 'fresh PowerShell smoke exists' $true (Test-Path -LiteralPath $freshInstall -PathType Leaf)
if (Test-Path -LiteralPath $freshInstall -PathType Leaf) {
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($freshInstall, [ref]$null, [ref]$parseErrors)
    Check 'fresh PowerShell smoke parses' 0 $parseErrors.Count
}
```

Add a package-script assertion that expects:

```json
"test:fresh:windows": "powershell -ExecutionPolicy Bypass -File test/fresh-install.ps1"
```

- [ ] **Step 2: Run on PowerShell and verify red**

Run: `powershell -ExecutionPolicy Bypass -File .\test.ps1`

Expected: failure `fresh PowerShell smoke exists` and the package-script assertion.

- [ ] **Step 3: Implement the PowerShell smoke script**

Create `test/fresh-install.ps1`. It must save and restore process environment,
use a GUID-named temp root, call `install.ps1 -ProfilePath`, dot-source the
written profile, and assert:

```powershell
if ((Get-Command claude).CommandType -ne 'Function') { throw 'claude is not a function' }
if ((Get-Command agent-profile).CommandType -ne 'Alias') { throw 'agent-profile is not an alias' }
if ((Get-Command claude-profile).CommandType -ne 'Alias') { throw 'claude-profile compatibility alias is missing' }
```

Set these values before invoking the installer:

```powershell
$env:HOME = Join-Path $root 'home'
$env:CLAUDE_PROFILES_DIR = Join-Path $env:HOME '.agent-profiles'
$profilePath = Join-Path $env:HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
```

Assert the profile imports `agent-profile.psm1`, not the compatibility module.
Always restore `HOME` and `CLAUDE_PROFILES_DIR` and remove the temp root in a
`finally` block. Print `fresh PowerShell clone install passed` on success.

- [ ] **Step 4: Run Windows smoke and suite**

Run: `powershell -ExecutionPolicy Bypass -File .\test\fresh-install.ps1`

Expected: `fresh PowerShell clone install passed`.

Run: `powershell -ExecutionPolicy Bypass -File .\test.ps1`

Expected: `failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add test/fresh-install.ps1 test.ps1 package.json
git commit -m "test: add fresh PowerShell install smoke"
```

### Task 3: Native GitHub Actions matrix

**Files:**
- Create: `.github/workflows/test.yml`

**Interfaces:**
- Consumes: checkout at the pull-request commit and the tarball artifact produced by `package`.
- Produces: required `package`, `posix (ubuntu-latest)`, `posix (macos-latest)`, and `windows` jobs plus uploaded test evidence.

- [ ] **Step 1: Add a failing workflow-presence assertion**

Add to `test.sh`:

```sh
check "native CI workflow exists" '[ -f "$HERE/.github/workflows/test.yml" ]'
check "native CI names all OS families" \
  'grep -q ubuntu-latest "$HERE/.github/workflows/test.yml" &&
   grep -q macos-latest "$HERE/.github/workflows/test.yml" &&
   grep -q windows-latest "$HERE/.github/workflows/test.yml"'
```

- [ ] **Step 2: Run and verify red**

Run: `npm test`

Expected: `native CI workflow exists` fails.

- [ ] **Step 3: Create the workflow**

Create `.github/workflows/test.yml` with:

- triggers for `pull_request`, pushes to `main`, `workflow_dispatch`, and a nightly cron;
- least-privilege `contents: read` permissions;
- concurrency cancellation per branch;
- a `package` job on Ubuntu that runs `npm test`, `npm pack --pack-destination dist`, and uploads `dist/*.tgz`;
- a `posix` matrix for `ubuntu-latest` and `macos-latest` that downloads the tarball, runs the checkout suite through `sh`, `bash`, and `zsh`, then runs `sh test/fresh-install.sh "$tarball"`;
- a `windows` job that runs `test.ps1` and `test/fresh-install.ps1` in Windows PowerShell 5.1 and PowerShell 7, plus `test.sh` through Git Bash;
- uploaded text logs and version evidence using `if: always()` and no config-file contents.

Use `actions/checkout@v4`, `actions/setup-node@v4` with Node 24, and
`actions/upload-artifact@v4`/`actions/download-artifact@v4`. Shell commands must
select the single downloaded tarball and fail when zero or multiple files exist.

- [ ] **Step 4: Validate locally**

Run: `npm test`

Expected: `all passed`.

Run: `git diff --check`

Expected: no output.

If `actionlint` is installed, run: `actionlint .github/workflows/test.yml`

Expected: no findings. Absence of `actionlint` is not a reason to install a new dependency.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/test.yml test.sh
git commit -m "ci: test fresh installs on native runners"
```

### Task 4: Document the executable support matrix

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: commands and job names delivered by Tasks 1-3.
- Produces: a Tests section that distinguishes hermetic, fresh-package, real-client, and manual coverage without claiming unimplemented adapters.

- [ ] **Step 1: Add a failing documentation assertion**

Add to `test.sh`:

```sh
check "README documents fresh package smoke" 'grep -q "test:fresh:posix" "$HERE/README.md"'
check "README documents native CI scope" 'grep -q "ubuntu-latest.*macos-latest.*windows-latest" "$HERE/README.md"'
```

- [ ] **Step 2: Run and verify red**

Run: `npm test`

Expected: both new README assertions fail.

- [ ] **Step 3: Update README**

Extend `## Tests` with:

```markdown
npm test
npm run test:fresh:posix
powershell -ExecutionPolicy Bypass -File .\test\fresh-install.ps1
```

State that pull requests run on `ubuntu-latest`, `macos-latest`, and
`windows-latest`; POSIX installs use the packed npm artifact; Windows follows
the clone plus `install.ps1` flow; and real authenticated client calls are not
part of this phase. Link the design spec for the later Gemini, local-provider,
nightly, and release-validation phases.

- [ ] **Step 4: Run final verification**

Run: `npm test`

Expected: `all passed`.

Run: `npm run test:fresh:posix`

Expected: `fresh POSIX package install passed`.

Run: `shellcheck agent-profile.sh claude-profile.sh install.sh lib/*.sh test.sh test/fresh-install.sh bin/claude`

Expected: no findings.

Run: `npm pack --dry-run --json`

Expected: package contents include canonical and compatibility entry points and exclude profile stores.

Run: `git diff --check`

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add README.md test.sh
git commit -m "docs: describe native fresh-install coverage"
```

## Follow-up plans

After this plan is green on all three hosted OS families, write and execute
separate plans in this order:

1. Windows shared-store, Codex, and npm-install parity.
2. Gemini CLI adapter and its acceptance fixture.
3. Ollama and LM Studio client-setting fixtures.
4. Nightly real-client and protected authenticated smoke workflows.
5. Release evidence generation and the manual GUI/WSL checklist.
