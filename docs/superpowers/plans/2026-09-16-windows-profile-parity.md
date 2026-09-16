# Windows Profile Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Windows use the shared profile store, switch Codex settings without symlink privileges, and support a stable npm installation path.

**Architecture:** Keep profile management in the existing POSIX implementation under Git Bash, but make the PowerShell wrapper own the Windows-only state that cannot use Unix symlinks. `install.ps1` copies the shipped code into `~/.agent-profile` before writing the PowerShell profile, so clone, npm postinstall, and the explicit npm installer all converge on one stable installation.

**Tech Stack:** Windows PowerShell 5.1, PowerShell 7, POSIX sh through Git for Windows, Node.js 24, npm, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-09-16-cross-platform-install-validation-design.md`

## Global Constraints

- Preserve `claude-profile`, `.claude-profile`, and `CLAUDE_PROFILE*` compatibility names.
- Canonical entry points remain `agent-profile.sh` and `agent-profile.psm1`.
- Do not require Developer Mode, administrator privileges, or Windows symlinks.
- Do not install AI providers, start provider processes, download models, or make authenticated requests.
- All tests use disposable homes, stores, install directories, profiles, and npm prefixes.
- Keep Windows PowerShell files ASCII-only for Windows PowerShell 5.1.

---

### Task 1: Shared Windows store default

**Files:**
- Modify: `agent-profile.psm1`
- Modify: `test.ps1`

**Interfaces:**
- Consumes: `$env:HOME`, with PowerShell `$HOME` as fallback.
- Produces: `Get-CpStore`, defaulting to `<home>/.agent-profiles` unless `CLAUDE_PROFILES_DIR` is set.

- [ ] **Step 1: Add failing tests**

Add assertions in `test.ps1` that run `Get-CpStore` with and without `CLAUDE_PROFILES_DIR`:

```powershell
$env:CLAUDE_PROFILES_DIR = $null
Check 'store: defaults under HOME' (Join-Path $fakeHome '.agent-profiles') (& $mod { Get-CpStore })
$env:CLAUDE_PROFILES_DIR = $store
Check 'store: honours override' $store (& $mod { Get-CpStore })
```

- [ ] **Step 2: Verify the default test fails on native Windows CI**

Run: `powershell -ExecutionPolicy Bypass -File .\test.ps1`

Expected: `store: defaults under HOME` reports the module directory instead of `<home>\.agent-profiles`.

- [ ] **Step 3: Implement the shared default**

Change `Get-CpStore` to reuse the same home resolution as `Get-CpBaseDir`:

```powershell
function Get-CpHome {
    if ($env:HOME) { return $env:HOME }
    return $HOME
}

function Get-CpStore {
    if ($env:CLAUDE_PROFILES_DIR) { return $env:CLAUDE_PROFILES_DIR }
    return (Join-Path (Get-CpHome) '.agent-profiles')
}
```

Make `Get-CpBaseDir` call `Get-CpHome`.

- [ ] **Step 4: Run the PowerShell suites**

Run on Windows PowerShell 5.1 and PowerShell 7: `powershell -ExecutionPolicy Bypass -File .\test.ps1`

Expected: `failed: 0` in both hosts.

- [ ] **Step 5: Commit**

```bash
git add agent-profile.psm1 test.ps1
git commit -m "fix: share the Windows profile store"
```

### Task 2: Native Codex settings switching on Windows

**Files:**
- Modify: `agent-profile.psm1`
- Modify: `test.ps1`

**Interfaces:**
- Consumes: `<home>/.codex/config.toml`, `<store>/active`, `<store>/codex-default.config.toml`, and `<store>/profiles/<name>/codex.config.toml`.
- Produces: `Set-CpActiveProfile` and `Set-CpDefaultProfile`; both copy settings atomically and update the active marker without symlinks.

- [ ] **Step 1: Add failing native switching tests**

In `test.ps1`, seed a default Codex config and two profile configs, then assert:

```powershell
& $mod { Set-CpActiveProfile 'work' }
Check 'codex: activates profile settings' 'model = "work"' ([IO.File]::ReadAllText($codexConfig).Trim())
Utf8NoBom $codexConfig 'model = "edited"'
& $mod { Set-CpActiveProfile 'finance' }
Check 'codex: snapshots outgoing profile' 'model = "edited"' ([IO.File]::ReadAllText($workCodex).Trim())
& $mod { Set-CpDefaultProfile }
Check 'codex: restores default settings' 'model = "default"' ([IO.File]::ReadAllText($codexConfig).Trim())
```

Also assert that `config.toml` is not a reparse point and that a missing profile config is seeded from the preserved default.

- [ ] **Step 2: Verify the tests fail**

Run: `powershell -ExecutionPolicy Bypass -File .\test.ps1`

Expected: `Set-CpActiveProfile` is not defined.

- [ ] **Step 3: Implement copy-based switching**

Add helpers that:

1. Resolve the live, default, and per-profile Codex paths.
2. Copy through `<destination>.tmp.<pid>` and `Move-Item -Force`.
3. Before a switch, copy the live config into the currently active profile, or preserve it as the default when no active marker exists.
4. Seed a missing target config from the preserved default.
5. Write or remove the active marker only after all copies succeed.

Intercept a single profile name and `default` in `Invoke-CpProfile`; continue delegating every other management command to Git Bash.

- [ ] **Step 4: Run native and drift tests**

Run on Windows PowerShell 5.1 and PowerShell 7: `powershell -ExecutionPolicy Bypass -File .\test.ps1`

Expected: `failed: 0`, including the existing PowerShell/Git Bash resolution drift cases.

- [ ] **Step 5: Commit**

```bash
git add agent-profile.psm1 test.ps1
git commit -m "feat: switch Codex settings natively on Windows"
```

### Task 3: Stable clone and npm installation

**Files:**
- Modify: `install.ps1`
- Modify: `scripts/postinstall.mjs`
- Modify: `test/fresh-install.ps1`
- Modify: `.github/workflows/test.yml`

**Interfaces:**
- Consumes: the checkout or unpacked npm package containing both entry modules, `lib/`, `bin/`, and installers.
- Produces: code copied to `<home>/.agent-profile`, a PowerShell profile importing `<home>/.agent-profile/agent-profile.psm1`, and an npm-installed `agent-profile-install` command that runs the same installer.

- [ ] **Step 1: Extend the fresh-install smoke and verify red**

Make `test/fresh-install.ps1` accept optional `-PackagePath`. In clone mode, assert the profile imports `<home>/.agent-profile/agent-profile.psm1`, not the checkout. In package mode:

```powershell
npm install --global --ignore-scripts --prefix $prefix $PackagePath
& (Join-Path $prefix 'agent-profile-install.cmd')
. $profilePath
```

Assert the stable code directory exists and the three exported surfaces load.

Run on Windows: `powershell -ExecutionPolicy Bypass -File .\test\fresh-install.ps1`

Expected: failure because `install.ps1` still writes an import pointing at the checkout.

- [ ] **Step 2: Copy shipped code into the stable directory**

Before constructing the import line, make `install.ps1` copy these entries into `<home>/.agent-profile` when `$selfDir` is different:

```text
agent-profile.psm1
agent-profile.sh
claude-profile.psm1
claude-profile.sh
install.ps1
install.sh
lib/
bin/
scripts/
```

Replace only those owned paths, refuse an install directory equal to the home directory, and then build `$module` and `$shim` from the stable directory.

- [ ] **Step 3: Run the installer from npm on Windows**

Replace the Windows guidance-only branch in `scripts/postinstall.mjs` with `spawnSync` of Windows PowerShell:

```javascript
const run = spawnSync('powershell.exe', [
  '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', join(root, 'install.ps1'),
], {stdio: 'inherit', cwd: root});
```

Keep the existing POSIX branch unchanged and propagate a non-zero child exit through `process.exitCode`.

- [ ] **Step 4: Add native package smoke to CI**

Pass the downloaded tarball to the PowerShell 7 fresh-install invocation:

```powershell
$package = @(Get-ChildItem -LiteralPath dist -Filter '*.tgz') | Select-Object -First 1
pwsh -NoLogo -File .\test\fresh-install.ps1 -PackagePath $package.FullName
```

Keep the Windows PowerShell 5.1 clone smoke so both hosts remain covered.

- [ ] **Step 5: Run native verification**

Run the GitHub Actions matrix.

Expected: package, Ubuntu, macOS, Windows PowerShell 5.1, PowerShell 7, clone install, and packed npm install all pass.

- [ ] **Step 6: Commit**

```bash
git add install.ps1 scripts/postinstall.mjs test/fresh-install.ps1 .github/workflows/test.yml
git commit -m "feat: install Windows package into a stable directory"
```

### Task 4: Document the supported Windows path

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the verified native behavior from Tasks 1-3.
- Produces: Windows instructions matching clone and npm fresh-install tests.

- [ ] **Step 1: Replace the temporary Windows limitations**

Document that:

- Git Bash and PowerShell default to `~/.agent-profiles`.
- Windows Codex switching uses file copies rather than symlinks.
- `npm i -g agent-profiles` installs automatically when npm permits scripts; otherwise run `agent-profile-install` once.
- `cmd.exe` remains unsupported.

- [ ] **Step 2: Run documentation and package checks**

Run: `npm test`

Expected: `all passed`.

Run: `npm pack --dry-run --json`

Expected: the canonical modules, compatibility shims, installers, `lib/`, `bin/`, and `scripts/` are present.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: describe Windows profile parity"
```

### Task 5: Final native verification

**Files:**
- Verify only.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a green native run and downloadable evidence artifacts for all three operating systems.

- [ ] **Step 1: Run local checks**

Run:

```bash
npm test
bash test.sh
npm run test:fresh:posix
git diff --check
```

Expected: all commands exit `0`.

- [ ] **Step 2: Push and watch native CI**

Run:

```bash
git push origin main
gh run watch --exit-status
```

Expected: package, Ubuntu, macOS, and Windows jobs all pass.
